// This probe is compiled inside the selected Orka source checkout so it tests
// the actual gateway resolver and HTTP Tool executor against a live gateway.
package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"os"
	"strings"
	"sync/atomic"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"

	corev1alpha1 "github.com/orka-agents/orka/api/v1alpha1"
	"github.com/orka-agents/orka/internal/outboundaccess"
	"github.com/orka-agents/orka/internal/worker"
)

const namespace = "orka-system"

func main() {
	gateway := flag.String("gateway", "", "loopback address of the gateway port-forward")
	authUnavailable := flag.Bool("auth-unavailable", false, "check failure with the ext-auth fixture stopped")
	flag.Parse()
	if err := run(*gateway, *authUnavailable); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(gateway string, authUnavailable bool) error {
	host, _, err := net.SplitHostPort(gateway)
	if err != nil || host != "127.0.0.1" {
		return errors.New("gateway must be a 127.0.0.1 port-forward address")
	}
	kubeconfig := os.Getenv("KUBECONFIG")
	if kubeconfig == "" {
		return errors.New("an explicit integration KUBECONFIG is required")
	}
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return fmt.Errorf("read integration kubeconfig: %w", err)
	}
	scheme := runtime.NewScheme()
	if err := corev1.AddToScheme(scheme); err != nil {
		return err
	}
	if err := corev1alpha1.AddToScheme(scheme); err != nil {
		return err
	}
	reader, err := client.New(config, client.Options{Scheme: scheme})
	if err != nil {
		return err
	}
	kube, err := kubernetes.NewForConfig(config)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	fixture := &corev1.Secret{}
	if err := reader.Get(ctx, client.ObjectKey{Namespace: namespace, Name: "agentgateway-fixture"}, fixture); err != nil {
		return fmt.Errorf("read synthetic fixture credentials: %w", err)
	}
	transaction := strings.TrimSpace(string(fixture.Data["txn-token"]))
	upstream := strings.TrimSpace(string(fixture.Data["upstream-authorization"]))
	if transaction == "" || upstream == "" {
		return errors.New("fixture credentials are incomplete")
	}
	if authUnavailable {
		// Distinguish a closed authorization gate from an unavailable Orka API.
		if _, err := kube.CoreV1().Services(namespace).ProxyGet("http", "orka", "8080", "healthz", nil).DoRaw(ctx); err != nil {
			return fmt.Errorf("Orka must remain healthy during the fail-closed check: %w", err)
		}
		if err := expectIngress(ctx, gateway, "orka.example.test", transaction, http.StatusForbidden, 500, 502, 503, 504); err != nil {
			return fmt.Errorf("ext-auth service failure was not closed: %w", err)
		}
		fmt.Println("ok: unavailable ext-auth denies access while Orka remains healthy")
		return nil
	}
	tool := &corev1alpha1.Tool{}
	if err := reader.Get(ctx, client.ObjectKey{Namespace: namespace, Name: "downstream-api"}, tool); err != nil {
		return fmt.Errorf("read applied Tool: %w", err)
	}
	if tool.Spec.HTTP == nil {
		return errors.New("applied Tool is missing its HTTP configuration")
	}
	const idempotencyKey = "agentgateway-conformance"
	tool.Spec.HTTP.Headers = map[string]string{
		"Authorization":   upstream,
		"Idempotency-Key": idempotencyKey,
	}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	transport.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		if address != "orka-egress.orka-system.svc:8080" {
			return nil, errors.New("Orka attempted to dial outside the configured gateway Service")
		}
		return (&net.Dialer{Timeout: 10 * time.Second}).DialContext(ctx, network, gateway)
	}
	defer transport.CloseIdleConnections()
	resolver := &outboundaccess.KubernetesResolver{Reader: reader}
	executor := worker.NewToolExecutorForNamespace(namespace, kube, &http.Client{Transport: transport}, resolver)
	executor.SetTransactionAuthority(transaction, nil)
	var sentTransaction, sentAuthorization atomic.Bool
	trace := &httptrace.ClientTrace{WroteHeaderField: func(key string, values []string) {
		if len(values) != 1 {
			return
		}
		if strings.EqualFold(key, "Txn-Token") && values[0] == transaction {
			sentTransaction.Store(true)
		}
		if strings.EqualFold(key, "Authorization") && values[0] == upstream {
			sentAuthorization.Store(true)
		}
	}}
	payload := json.RawMessage(`{"message":"gateway-conformance"}`)
	result, err := executor.Execute(httptrace.WithClientTrace(ctx, trace), tool, payload)
	if err != nil {
		return fmt.Errorf("execute Orka HTTP Tool through agentgateway: %w", err)
	}
	var observed struct {
		AuthorizationReplaced bool   `json:"authorization_replaced"`
		TransactionRemoved    bool   `json:"governance_header_absent"`
		Method                string `json:"method"`
		Host                  string `json:"host"`
		Path                  string `json:"path"`
		BodyDigest            string `json:"body_sha256"`
		IdempotencyDigest     string `json:"idempotency_key_sha256"`
	}
	if err := json.Unmarshal([]byte(result), &observed); err != nil {
		return errors.New("downstream did not return valid conformance evidence")
	}
	if !sentTransaction.Load() || !sentAuthorization.Load() {
		return errors.New("Orka did not send both governance and explicit authorization headers to the gateway")
	}
	if !observed.AuthorizationReplaced || !observed.TransactionRemoved {
		return errors.New("gateway did not replace authorization and strip the transaction token")
	}
	if observed.Method != "POST" || observed.Host != "example.com" || observed.Path != "/v1/resource?version=1" ||
		observed.BodyDigest != fmt.Sprintf("%x", sha256.Sum256(payload)) ||
		observed.IdempotencyDigest != fmt.Sprintf("%x", sha256.Sum256([]byte(idempotencyKey))) {
		return errors.New("gateway changed the Tool method, authority, path, query, body, or idempotency key")
	}
	fmt.Println("ok: Orka HTTP Tool preserves the request and gateway replaces authorization without leaking Txn-Token")
	for _, check := range []struct {
		name, authority, token string
		status                 int
	}{
		{"valid ext-auth token", "orka.example.test", transaction, http.StatusOK},
		{"missing ext-auth token", "orka.example.test", "", http.StatusForbidden},
		{"invalid ext-auth token", "orka.example.test", "invalid-fixture-token", http.StatusForbidden},
		{"unconfigured authority", "unconfigured.example.test", transaction, http.StatusNotFound},
	} {
		if err := expectIngress(ctx, gateway, check.authority, check.token, check.status); err != nil {
			return fmt.Errorf("%s: %w", check.name, err)
		}
		fmt.Println("ok:", check.name)
	}
	return nil
}

func expectIngress(ctx context.Context, gateway, authority, token string, statuses ...int) error {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.Proxy = nil
	defer transport.CloseIdleConnections()
	httpClient := &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	// Gateway configuration and EndpointSlice changes propagate asynchronously.
	deadline := time.Now().Add(30 * time.Second)
	lastStatus := 0
	for {
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://"+gateway+"/healthz", nil)
		if err != nil {
			return err
		}
		request.Host = authority
		if token != "" {
			request.Header.Set("Txn-Token", token)
		}
		response, err := httpClient.Do(request)
		if err != nil {
			return errors.New("gateway ingress request failed")
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 4096))
		_ = response.Body.Close()
		lastStatus = response.StatusCode
		for _, expected := range statuses {
			if lastStatus == expected {
				return nil
			}
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("unexpected HTTP status %d", lastStatus)
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(time.Second):
		}
	}
}
