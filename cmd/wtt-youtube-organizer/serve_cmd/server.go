package serve_cmd

import (
	"context"
	"github.com/grandcat/zeroconf"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type cachedStream struct {
	directURL string
	expiresAt time.Time
}

// Server provides the HTTP media streaming proxy and UDP discovery service.
type Server struct {
	httpPort    int
	udpPort     int
	cookiesPath string
	instanceID  string
	hostname    string

	cacheMu sync.RWMutex
	cache   map[string]*cachedStream
}

// NewServer initializes a new Server instance.
func NewServer(httpPort, udpPort int, cookiesPath string) *Server {
	hostname, _ := os.Hostname()
	if hostname == "" {
		hostname = "wtt-server"
	}

	return &Server{
		httpPort:    httpPort,
		udpPort:     udpPort,
		cookiesPath: cookiesPath,
		instanceID:  getOrCreateInstanceID(),
		hostname:    hostname,
		cache:       make(map[string]*cachedStream),
	}
}

func getOrCreateInstanceID() string {
	home, _ := os.UserHomeDir()
	path := filepath.Join(home, ".config", "wtt-youtube-organizer", "server_instance_id")
	if data, err := os.ReadFile(path); err == nil && len(strings.TrimSpace(string(data))) > 0 {
		return strings.TrimSpace(string(data))
	}

	bytes := make([]byte, 16)
	_, _ = rand.Read(bytes)
	newID := "wtt-srv-" + hex.EncodeToString(bytes)

	_ = os.MkdirAll(filepath.Dir(path), 0755)
	_ = os.WriteFile(path, []byte(newID), 0644)
	return newID
}

// Start launches both the HTTP streaming server and the UDP discovery listener.
func (s *Server) Start() error {
	// 1. Register Chromecast-standard mDNS (Multicast DNS on 224.0.0.251:5353)
	mdnsServer, err := zeroconf.Register(
		"WTT-Stream-Proxy",
		"_wtt-proxy._tcp",
		"local.",
		s.httpPort,
		[]string{"id=" + s.instanceID, "version=1.0"},
		nil,
	)
	if err != nil {
		fmt.Printf("⚠️ [mDNS] Failed to register mDNS service: %v\n", err)
	} else {
		defer mdnsServer.Shutdown()
		fmt.Printf("📡 [mDNS] Registered service _wtt-proxy._tcp.local on port %d (Chromecast standard)\n", s.httpPort)
	}

	// 2. Start UDP Discovery Listener in background
	go s.listenUDPDiscovery()

	// 2. Start HTTP Proxy Server
	mux := http.NewServeMux()
	mux.HandleFunc("/health", s.handleHealth)
	mux.HandleFunc("/api/resolve/", s.handleResolve)
	mux.HandleFunc("/stream/", s.handleStream)

	addr := fmt.Sprintf("0.0.0.0:%d", s.httpPort)
	fmt.Printf("🚀 [SERVER] WTT Stream Proxy listening on HTTP http://%s (Instance: %s)\n", addr, s.instanceID)
	return http.ListenAndServe(addr, mux)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"status":      "ok",
		"service":     "wtt-stream-proxy",
		"instance_id": s.instanceID,
		"hostname":    s.hostname,
		"version":     "1.0",
		"http_port":   s.httpPort,
	})
}

type resolveStreamItem struct {
	Height int    `json:"height"`
	URL    string `json:"url"`
}

type resolveResponse struct {
	VideoStreams []resolveStreamItem `json:"videoStreams"`
	AudioURL     string              `json:"audioUrl,omitempty"`
	HttpHeaders  map[string]string   `json:"httpHeaders"`
}

// handleResolve uses yt-dlp to extract available formats and returns proxy stream URLs.
func (s *Server) handleResolve(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Content-Type", "application/json")

	videoID := strings.TrimPrefix(r.URL.Path, "/api/resolve/")
	videoID = strings.TrimSpace(videoID)
	if videoID == "" {
		http.Error(w, `{"error":"missing video_id"}`, http.StatusBadRequest)
		return
	}

	host := r.Host
	if host == "" {
		host = fmt.Sprintf("127.0.0.1:%d", s.httpPort)
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	baseURL := fmt.Sprintf("%s://%s", scheme, host)

	// Available standard video formats we proxy: 1080p (312/299/137), 720p (136/22), 480p (135/18), 360p (134)
	resp := resolveResponse{
		VideoStreams: []resolveStreamItem{
			{Height: 1080, URL: fmt.Sprintf("%s/stream/%s?format=312/299/137/bv*[height<=1080]", baseURL, videoID)},
			{Height: 720, URL: fmt.Sprintf("%s/stream/%s?format=136/22/bv*[height<=720]", baseURL, videoID)},
			{Height: 480, URL: fmt.Sprintf("%s/stream/%s?format=135/18/bv*[height<=480]", baseURL, videoID)},
			{Height: 360, URL: fmt.Sprintf("%s/stream/%s?format=134/bv*[height<=360]", baseURL, videoID)},
		},
		AudioURL: fmt.Sprintf("%s/stream/%s?format=234/140/251/ba", baseURL, videoID),
		HttpHeaders: map[string]string{
			"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
		},
	}

	_ = json.NewEncoder(w).Encode(resp)
}

// handleStream forwards the request to GoogleVideo with HTTP Range support.
func (s *Server) handleStream(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Range, Content-Type, Accept")
	w.Header().Set("Accept-Ranges", "bytes")

	if r.Method == "OPTIONS" {
		w.WriteHeader(http.StatusOK)
		return
	}

	videoID := strings.TrimPrefix(r.URL.Path, "/stream/")
	videoID = strings.TrimSpace(videoID)
	if videoID == "" {
		http.Error(w, "missing video_id", http.StatusBadRequest)
		return
	}

	format := r.URL.Query().Get("format")
	if format == "" {
		format = "18/bv*/b"
	}

	directURL, err := s.resolveDirectURL(r.Context(), videoID, format)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to resolve stream: %v", err), http.StatusBadGateway)
		return
	}

	proxyReq, err := http.NewRequestWithContext(r.Context(), "GET", directURL, nil)
	if err != nil {
		http.Error(w, "failed to create proxy request", http.StatusInternalServerError)
		return
	}

	// Forward client Range header for seeking/scrubbing
	if rangeHeader := r.Header.Get("Range"); rangeHeader != "" {
		proxyReq.Header.Set("Range", rangeHeader)
	}
	proxyReq.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

	client := &http.Client{Timeout: 0}
	resp, err := client.Do(proxyReq)
	if err != nil {
		http.Error(w, fmt.Sprintf("stream fetch failed: %v", err), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Copy upstream headers
	for _, key := range []string{"Content-Range", "Content-Length", "Content-Type", "Accept-Ranges"} {
		if val := resp.Header.Get(key); val != "" {
			w.Header().Set(key, val)
		}
	}
	w.WriteHeader(resp.StatusCode)

	_, _ = io.Copy(w, resp.Body)
}

func (s *Server) resolveDirectURL(ctx context.Context, videoID, format string) (string, error) {
	cacheKey := fmt.Sprintf("%s:%s", videoID, format)

	s.cacheMu.RLock()
	item, found := s.cache[cacheKey]
	s.cacheMu.RUnlock()

	if found && time.Now().Before(item.expiresAt) {
		return item.directURL, nil
	}

	// Resolve using yt-dlp on the server with cookies
	args := []string{
		"-g",
		"-f", format,
		"--no-warnings",
	}

	if s.cookiesPath != "" {
		if _, err := os.Stat(s.cookiesPath); err == nil {
			args = append(args, "--cookies", s.cookiesPath)
		}
	}

	args = append(args, fmt.Sprintf("https://www.youtube.com/watch?v=%s", videoID))

	cmd := exec.CommandContext(ctx, "yt-dlp", args...)
	out, err := cmd.Output()
	if err != nil {
		return "", fmt.Errorf("yt-dlp error: %w", err)
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) == 0 || lines[0] == "" {
		return "", fmt.Errorf("empty stream URL from yt-dlp")
	}

	directURL := lines[0]

	s.cacheMu.Lock()
	s.cache[cacheKey] = &cachedStream{
		directURL: directURL,
		expiresAt: time.Now().Add(4 * time.Hour),
	}
	s.cacheMu.Unlock()

	return directURL, nil
}

// listenUDPDiscovery responds to broadcast discovery requests on the LAN.
func (s *Server) listenUDPDiscovery() {
	addr := net.UDPAddr{
		Port: s.udpPort,
		IP:   net.ParseIP("0.0.0.0"),
	}

	conn, err := net.ListenUDP("udp4", &addr)
	if err != nil {
		fmt.Printf("⚠️ [DISCOVERY] Failed to bind UDP %d: %v\n", s.udpPort, err)
		return
	}
	defer conn.Close()

	fmt.Printf("📡 [DISCOVERY] UDP broadcast listener active on port %d\n", s.udpPort)

	// Broadcast beacon every 3 seconds to active subnets
	go func() {
		ticker := time.NewTicker(3 * time.Second)
		defer ticker.Stop()

		beacon := map[string]interface{}{
			"service":     "wtt-stream-proxy",
			"http_port":   s.httpPort,
			"instance_id": s.instanceID,
			"hostname":    s.hostname,
		}
		beaconBytes, _ := json.Marshal(beacon)

		for range ticker.C {
			_, _ = conn.WriteToUDP(beaconBytes, &net.UDPAddr{IP: net.ParseIP("255.255.255.255"), Port: s.udpPort})

			ifaces, err := net.Interfaces()
			if err == nil {
				for _, iface := range ifaces {
					if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
						continue
					}
					addrs, err := iface.Addrs()
					if err == nil {
						for _, addr := range addrs {
							if ipnet, ok := addr.(*net.IPNet); ok && ipnet.IP.To4() != nil {
								ip := ipnet.IP.To4()
								mask := ipnet.Mask
								broadcast := net.IP(make([]byte, 4))
								for i := 0; i < 4; i++ {
									broadcast[i] = ip[i] | ^mask[i]
								}
								_, _ = conn.WriteToUDP(beaconBytes, &net.UDPAddr{IP: broadcast, Port: s.udpPort})
							}
						}
					}
				}
			}
		}
	}()

	buf := make([]byte, 1024)
	for {
		n, remoteAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			continue
		}

		msg := strings.TrimSpace(string(buf[:n]))
		if strings.HasPrefix(msg, "WTT_PROXY_DISCOVERY_PING") {
			resp := map[string]interface{}{
				"service":     "wtt-stream-proxy",
				"http_port":   s.httpPort,
				"instance_id": s.instanceID,
				"hostname":    s.hostname,
			}
			respBytes, _ := json.Marshal(resp)
			_, _ = conn.WriteToUDP(respBytes, remoteAddr)
		}
	}
}
