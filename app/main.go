package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"
)

func env(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func intQuery(r *http.Request, key string, fallback, maxValue int) int {
	raw := r.URL.Query().Get(key)
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return fallback
	}
	if value > maxValue {
		return maxValue
	}
	return value
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func serverHandler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("/api/data", func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		delayMs := intQuery(r, "server_delay_ms", 0, 30000)
		responseSize := intQuery(r, "response_size", 128, 1024*1024)

		if delayMs > 0 {
			time.Sleep(time.Duration(delayMs) * time.Millisecond)
		}

		body := bytes.Repeat([]byte("x"), responseSize)
		processingMs := float64(time.Since(started).Microseconds()) / 1000.0

		w.Header().Set("Content-Type", "application/octet-stream")
		w.Header().Set("X-App-Processing-Ms", fmt.Sprintf("%.3f", processingMs))
		w.Header().Set("X-Benchmark-Method", r.Method)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
	})

	mux.HandleFunc("/admin", func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		processingMs := float64(time.Since(started).Microseconds()) / 1000.0
		w.Header().Set("X-App-Processing-Ms", fmt.Sprintf("%.3f", processingMs))
		writeJSON(w, http.StatusOK, map[string]string{"status": "admin-ok"})
	})

	return mux
}

func clientHandler() http.Handler {
	mux := http.NewServeMux()

	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})

	mux.HandleFunc("/proxy", func(w http.ResponseWriter, r *http.Request) {
		target := r.URL.Query().Get("target")
		if target == "" {
			target = env("UPSTREAM_URL", "http://server:8080/api/data")
		}

		parsed, err := url.Parse(target)
		if err != nil {
			http.Error(w, "invalid target", http.StatusBadRequest)
			return
		}

		q := parsed.Query()
		for key, values := range r.URL.Query() {
			if key == "target" {
				continue
			}
			for _, value := range values {
				q.Add(key, value)
			}
		}
		parsed.RawQuery = q.Encode()

		var body io.Reader
		if r.Body != nil {
			payload, _ := io.ReadAll(r.Body)
			body = bytes.NewReader(payload)
		}

		req, err := http.NewRequestWithContext(r.Context(), r.Method, parsed.String(), body)
		if err != nil {
			http.Error(w, "request creation failed", http.StatusInternalServerError)
			return
		}
		req.Header = r.Header.Clone()

		started := time.Now()
		response, err := http.DefaultClient.Do(req)
		upstreamMs := float64(time.Since(started).Microseconds()) / 1000.0
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer response.Body.Close()

		for key, values := range response.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}
		w.Header().Set("X-Upstream-Latency-Ms", fmt.Sprintf("%.3f", upstreamMs))
		w.WriteHeader(response.StatusCode)
		_, _ = io.Copy(w, response.Body)
	})

	return mux
}

func serve(address string, handler http.Handler) {
	server := &http.Server{
		Addr:              address,
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("listening on %s", address)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("listen %s: %v", address, err)
	}
}

func main() {
	role := strings.ToLower(env("ROLE", "server"))
	switch role {
	case "server":
		handler := serverHandler()
		go serve(":8081", handler)
		serve(":8080", handler)
	case "client":
		serve(":8080", clientHandler())
	default:
		log.Fatalf("unknown ROLE=%q", role)
	}
}
