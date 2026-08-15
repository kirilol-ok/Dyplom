package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	defaultPort             = 8080
	defaultShutdownTimeout  = 10 * time.Second
	defaultMaxRequestBytes  = 64 << 20
	defaultMaxResponseBytes = 64 << 20
)

type config struct {
	port             int
	logRequests      bool
	shutdownTimeout  time.Duration
	maxRequestBytes  int64
	maxResponseBytes int
}

type jsonMap map[string]any

type app struct {
	cfg config
}

func main() {
	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("configuration error: %v", err)
	}

	a := &app{cfg: cfg}
	server := &http.Server{
		Addr:              fmt.Sprintf(":%d", cfg.port),
		Handler:           a.routes(),
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       90 * time.Second,
		MaxHeaderBytes:    1 << 20,
	}

	errCh := make(chan error, 1)
	go func() {
		log.Printf("benchmark server listening port=%d log_requests=%t", cfg.port, cfg.logRequests)
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
		close(errCh)
	}()

	stopCh := make(chan os.Signal, 1)
	signal.Notify(stopCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-stopCh:
		log.Printf("received signal %s, shutting down", sig)
	case err := <-errCh:
		if err != nil {
			log.Fatalf("HTTP server failed: %v", err)
		}
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), cfg.shutdownTimeout)
	defer cancel()
	if err := server.Shutdown(ctx); err != nil {
		log.Printf("graceful shutdown failed: %v", err)
		_ = server.Close()
	}
}

func loadConfig() (config, error) {
	portDefault, err := envInt("PORT", defaultPort)
	if err != nil {
		return config{}, err
	}
	logDefault, err := envBool("LOG_REQUESTS", false)
	if err != nil {
		return config{}, err
	}
	shutdownDefault, err := envDuration("SHUTDOWN_TIMEOUT", defaultShutdownTimeout)
	if err != nil {
		return config{}, err
	}
	maxRequestDefault, err := envInt64("MAX_REQUEST_BYTES", defaultMaxRequestBytes)
	if err != nil {
		return config{}, err
	}
	maxResponseDefault, err := envInt("MAX_RESPONSE_BYTES", defaultMaxResponseBytes)
	if err != nil {
		return config{}, err
	}

	cfg := config{}
	flag.IntVar(&cfg.port, "port", portDefault, "HTTP listen port")
	flag.BoolVar(&cfg.logRequests, "log-requests", logDefault, "log every request")
	flag.DurationVar(&cfg.shutdownTimeout, "shutdown-timeout", shutdownDefault, "graceful shutdown timeout")
	flag.Int64Var(&cfg.maxRequestBytes, "max-request-bytes", maxRequestDefault, "maximum request body size")
	flag.IntVar(&cfg.maxResponseBytes, "max-response-bytes", maxResponseDefault, "maximum synthetic response data size")
	flag.Parse()

	if cfg.port < 1 || cfg.port > 65535 {
		return config{}, fmt.Errorf("invalid port %d", cfg.port)
	}
	if cfg.maxRequestBytes < 0 {
		return config{}, errors.New("max-request-bytes must not be negative")
	}
	if cfg.maxResponseBytes < 0 {
		return config{}, errors.New("max-response-bytes must not be negative")
	}
	return cfg, nil
}

func (a *app) routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", a.healthHandler)
	mux.HandleFunc("/api/data", a.apiHandler)
	mux.HandleFunc("/admin", a.adminHandler)
	mux.HandleFunc("/", a.notFoundHandler)
	return a.requestLogger(mux)
}

func (a *app) requestLogger(next http.Handler) http.Handler {
	if !a.cfg.logRequests {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("remote=%s method=%s path=%s elapsed=%s", r.RemoteAddr, r.Method, r.URL.RequestURI(), time.Since(started))
	})
}

func (a *app) healthHandler(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	if r.Method != http.MethodGet {
		a.writeJSON(w, http.StatusMethodNotAllowed, jsonMap{"status": "method_not_allowed"}, started)
		return
	}
	responseSize, err := a.responseSize(r)
	if err != nil {
		a.writeJSON(w, http.StatusBadRequest, jsonMap{"status": "bad_request", "error": err.Error()}, started)
		return
	}
	payload := jsonMap{"status": "ok"}
	addSyntheticData(payload, responseSize)
	a.writeJSON(w, http.StatusOK, payload, started)
}

func (a *app) apiHandler(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	if err := discardRequestBody(r.Body, a.cfg.maxRequestBytes); err != nil {
		a.writeJSON(w, http.StatusRequestEntityTooLarge, jsonMap{"status": "request_too_large", "error": err.Error()}, started)
		return
	}

	responseSize, err := a.responseSize(r)
	if err != nil {
		a.writeJSON(w, http.StatusBadRequest, jsonMap{"status": "bad_request", "error": err.Error()}, started)
		return
	}

	delayMS, err := nonNegativeInt(r.URL.Query().Get("server_delay_ms"), 0)
	if err != nil {
		a.writeJSON(w, http.StatusBadRequest, jsonMap{"status": "bad_request", "error": err.Error()}, started)
		return
	}
	if delayMS > 0 {
		time.Sleep(time.Duration(delayMS) * time.Millisecond)
	}

	payload := jsonMap{
		"status": "api",
		"method": r.Method,
		"path":   r.URL.Path,
	}
	addSyntheticData(payload, responseSize)
	a.writeJSON(w, http.StatusOK, payload, started)
}

func (a *app) adminHandler(w http.ResponseWriter, r *http.Request) {
	started := time.Now()
	responseSize, err := a.responseSize(r)
	if err != nil {
		a.writeJSON(w, http.StatusBadRequest, jsonMap{"status": "bad_request", "error": err.Error()}, started)
		return
	}
	payload := jsonMap{"status": "admin", "method": r.Method}
	addSyntheticData(payload, responseSize)
	a.writeJSON(w, http.StatusOK, payload, started)
}

func (a *app) notFoundHandler(w http.ResponseWriter, r *http.Request) {
	a.writeJSON(w, http.StatusNotFound, jsonMap{"status": "not_found", "path": r.URL.Path}, time.Now())
}

func (a *app) responseSize(r *http.Request) (int, error) {
	size, err := nonNegativeInt(r.URL.Query().Get("response_size"), 0)
	if err != nil {
		return 0, err
	}
	if size > a.cfg.maxResponseBytes {
		return 0, fmt.Errorf("response_size exceeds maximum %d", a.cfg.maxResponseBytes)
	}
	return size, nil
}

func (a *app) writeJSON(w http.ResponseWriter, status int, payload any, started time.Time) {
	raw, err := json.Marshal(payload)
	if err != nil {
		status = http.StatusInternalServerError
		raw = []byte(`{"status":"encoding_error"}`)
	}

	processing := time.Since(started)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(raw)))
	w.Header().Set("X-App-Processing-Ms", fmt.Sprintf("%.3f", float64(processing.Microseconds())/1000.0))
	w.Header().Set("Server", "diploma-benchmark-server-go/2.0")
	w.WriteHeader(status)
	_, _ = w.Write(raw)
}

func addSyntheticData(payload jsonMap, size int) {
	if size > 0 {
		payload["data"] = strings.Repeat("x", size)
	}
}

func discardRequestBody(body io.ReadCloser, maxBytes int64) error {
	defer body.Close()
	if maxBytes == 0 {
		_, err := io.Copy(io.Discard, body)
		return err
	}
	limited := io.LimitReader(body, maxBytes+1)
	read, err := io.Copy(io.Discard, limited)
	if err != nil {
		return err
	}
	if read > maxBytes {
		return fmt.Errorf("request body exceeds %d bytes", maxBytes)
	}
	return nil
}

func nonNegativeInt(value string, fallback int) (int, error) {
	if strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 0 {
		return 0, fmt.Errorf("invalid non-negative integer %q", value)
	}
	return parsed, nil
}

func envBool(name string, fallback bool) (bool, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseBool(value)
	if err != nil {
		return false, fmt.Errorf("invalid %s=%q: %w", name, value, err)
	}
	return parsed, nil
}

func envInt(name string, fallback int) (int, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	parsed, err := strconv.Atoi(value)
	if err != nil {
		return 0, fmt.Errorf("invalid %s=%q: %w", name, value, err)
	}
	return parsed, nil
}

func envInt64(name string, fallback int64) (int64, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("invalid %s=%q: %w", name, value, err)
	}
	return parsed, nil
}

func envDuration(name string, fallback time.Duration) (time.Duration, error) {
	value, ok := os.LookupEnv(name)
	if !ok || strings.TrimSpace(value) == "" {
		return fallback, nil
	}
	parsed, err := time.ParseDuration(value)
	if err != nil {
		return 0, fmt.Errorf("invalid %s=%q: %w", name, value, err)
	}
	return parsed, nil
}
