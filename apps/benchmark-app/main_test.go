package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testConfig() config {
	return config{
		port:             8080,
		shutdownTimeout:  defaultShutdownTimeout,
		maxRequestBytes:  defaultMaxRequestBytes,
		maxResponseBytes: defaultMaxResponseBytes,
	}
}

func TestHealth(t *testing.T) {
	a := &app{cfg: testConfig()}
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d", rec.Code)
	}
	if rec.Header().Get("X-App-Processing-Ms") == "" {
		t.Fatal("missing X-App-Processing-Ms")
	}
}

func TestAPIData(t *testing.T) {
	a := &app{cfg: testConfig()}
	req := httptest.NewRequest(http.MethodPost, "/api/data?response_size=8&server_delay_ms=0", strings.NewReader("abcd"))
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d body=%s", rec.Code, rec.Body.String())
	}

	var payload map[string]any
	if err := json.Unmarshal(rec.Body.Bytes(), &payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload["status"] != "api" || payload["method"] != http.MethodPost || payload["data"] != "xxxxxxxx" {
		t.Fatalf("unexpected payload: %#v", payload)
	}
}

func TestAdmin(t *testing.T) {
	a := &app{cfg: testConfig()}
	req := httptest.NewRequest(http.MethodGet, "/admin", nil)
	rec := httptest.NewRecorder()
	a.routes().ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("unexpected status: %d", rec.Code)
	}
}
