package serve_cmd

import (
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestServer_HealthEndpoint(t *testing.T) {
	srv := NewServer(8080, 8081, "")
	req := httptest.NewRequest("GET", "/health", nil)
	w := httptest.NewRecorder()

	srv.handleHealth(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", resp.StatusCode)
	}

	var data map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		t.Fatalf("failed to decode json: %v", err)
	}

	if data["status"] != "ok" {
		t.Errorf("expected status 'ok', got %v", data["status"])
	}
	if data["service"] != "wtt-stream-proxy" {
		t.Errorf("expected service 'wtt-stream-proxy', got %v", data["service"])
	}
	if id, ok := data["instance_id"].(string); !ok || !strings.HasPrefix(id, "wtt-srv-") {
		t.Errorf("expected instance_id starting with 'wtt-srv-', got %v", data["instance_id"])
	}
}

func TestServer_ResolveEndpoint(t *testing.T) {
	srv := NewServer(8080, 8081, "")
	req := httptest.NewRequest("GET", "/api/resolve/tfAOXHia7tI", nil)
	req.Host = "192.168.1.50:8080"
	w := httptest.NewRecorder()

	srv.handleResolve(w, req)

	resp := w.Result()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", resp.StatusCode)
	}

	var data resolveResponse
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		t.Fatalf("failed to decode json: %v", err)
	}

	if len(data.VideoStreams) != 4 {
		t.Fatalf("expected 4 video streams, got %d", len(data.VideoStreams))
	}
	if data.VideoStreams[0].Height != 1080 {
		t.Errorf("expected stream 0 height 1080, got %d", data.VideoStreams[0].Height)
	}
	if !strings.Contains(data.VideoStreams[0].URL, "/stream/tfAOXHia7tI") {
		t.Errorf("expected stream url to contain video ID, got %s", data.VideoStreams[0].URL)
	}
	if !strings.Contains(data.AudioURL, "/stream/tfAOXHia7tI") {
		t.Errorf("expected audio url to contain video ID, got %s", data.AudioURL)
	}
}

func TestServer_UDPDiscovery(t *testing.T) {
	// Bind to an ephemeral port for test isolation
	srv := NewServer(8080, 0, "")

	// Use custom UDP port for test
	addr := net.UDPAddr{Port: 0, IP: net.ParseIP("127.0.0.1")}
	serverConn, err := net.ListenUDP("udp4", &addr)
	if err != nil {
		t.Fatalf("failed to listen UDP: %v", err)
	}
	defer serverConn.Close()

	srvPort := serverConn.LocalAddr().(*net.UDPAddr).Port

	// Start server handler in goroutine
	go func() {
		buf := make([]byte, 1024)
		n, remoteAddr, err := serverConn.ReadFromUDP(buf)
		if err != nil {
			return
		}
		if strings.HasPrefix(string(buf[:n]), "WTT_PROXY_DISCOVERY_PING") {
			resp := map[string]interface{}{
				"service":     "wtt-stream-proxy",
				"http_port":   srv.httpPort,
				"instance_id": srv.instanceID,
				"hostname":    srv.hostname,
			}
			respBytes, _ := json.Marshal(resp)
			_, _ = serverConn.WriteToUDP(respBytes, remoteAddr)
		}
	}()

	// Client sends ping
	clientConn, err := net.DialUDP("udp4", nil, &net.UDPAddr{
		Port: srvPort,
		IP:   net.ParseIP("127.0.0.1"),
	})
	if err != nil {
		t.Fatalf("failed to dial UDP: %v", err)
	}
	defer clientConn.Close()

	_ = clientConn.SetDeadline(time.Now().Add(2 * time.Second))
	_, err = clientConn.Write([]byte("WTT_PROXY_DISCOVERY_PING"))
	if err != nil {
		t.Fatalf("write failed: %v", err)
	}

	replyBuf := make([]byte, 1024)
	n, _, err := clientConn.ReadFrom(replyBuf)
	if err != nil {
		t.Fatalf("failed to read discovery reply: %v", err)
	}

	var reply map[string]interface{}
	if err := json.Unmarshal(replyBuf[:n], &reply); err != nil {
		t.Fatalf("invalid json reply: %v", err)
	}

	if reply["service"] != "wtt-stream-proxy" {
		t.Errorf("expected service 'wtt-stream-proxy', got %v", reply["service"])
	}
	if reply["instance_id"] != srv.instanceID {
		t.Errorf("expected instance_id %s, got %v", srv.instanceID, reply["instance_id"])
	}
}
