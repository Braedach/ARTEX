package server

import (
	"net/http/httptest"
	"testing"
)

func TestExtractTokenQueryOnlyForEventStream(t *testing.T) {
	r := httptest.NewRequest("GET", "/api/tasks?token=abc", nil)
	if got := extractToken(r); got != "" {
		t.Fatalf("query token accepted on a plain request: %q", got)
	}
	r = httptest.NewRequest("GET", "/api/logs/stream?token=abc", nil)
	r.Header.Set("Accept", "text/event-stream")
	if got := extractToken(r); got != "abc" {
		t.Fatalf("query token rejected on an event stream: %q", got)
	}
	r = httptest.NewRequest("POST", "/api/tasks?token=abc", nil)
	r.Header.Set("Accept", "text/event-stream")
	if got := extractToken(r); got != "" {
		t.Fatalf("query token accepted on POST: %q", got)
	}
}

func TestSelfUpdateDisabledEnv(t *testing.T) {
	t.Setenv("ARTEX_DISABLE_SELFUPDATE", "1")
	if !selfUpdateDisabled() {
		t.Fatal("expected disabled")
	}
	t.Setenv("ARTEX_DISABLE_SELFUPDATE", "")
	if selfUpdateDisabled() {
		t.Fatal("expected enabled")
	}
}
