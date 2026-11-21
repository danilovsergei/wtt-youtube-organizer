package serve_cmd

import (
	"context"
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
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/grandcat/zeroconf"
)

type cachedStream struct {
	directURL string
	expiresAt time.Time
}

type YtFormat struct {
	FormatID string  `json:"format_id"`
	URL      string  `json:"url"`
	VCodec   string  `json:"vcodec"`
	ACodec   string  `json:"acodec"`
	Height   int     `json:"height"`
	ABR      float64 `json:"abr"`
	Protocol string  `json:"protocol"`
}

type YtManifest struct {
	Formats []YtFormat `json:"formats"`
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
	manifestFn func(ctx context.Context, videoID string) (*YtManifest, error)
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

// Start launches both the HTTP streaming server, mDNS registration, and UDP discovery.
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

	// 3. Start HTTP Proxy Server
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

func resolveBinary(name string, fallbacks []string) string {
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	for _, f := range fallbacks {
		if _, err := os.Stat(f); err == nil {
			return f
		}
	}
	return name
}

func (s *Server) extractManifest(ctx context.Context, videoID string) (*YtManifest, error) {
	home, _ := os.UserHomeDir()
	ytdlpPath := resolveBinary("yt-dlp", []string{
		filepath.Join(home, "bin", "yt-dlp"),
		filepath.Join(home, ".local", "bin", "yt-dlp"),
		"/usr/local/bin/yt-dlp",
		"/usr/bin/yt-dlp",
	})

	denoPath := resolveBinary("deno", []string{
		filepath.Join(home, "bin", "deno"),
		filepath.Join(home, ".local", "bin", "deno"),
		"/usr/local/bin/deno",
		"/usr/bin/deno",
	})

	args := []string{
		"--js-runtimes", fmt.Sprintf("deno:%s", denoPath),
		"-j",
		"--no-warnings",
	}

	if s.cookiesPath != "" {
		if _, err := os.Stat(s.cookiesPath); err == nil {
			args = append(args, "--cookies", s.cookiesPath)
		}
	}

	args = append(args, fmt.Sprintf("https://www.youtube.com/watch?v=%s", videoID))

	cmd := exec.CommandContext(ctx, ytdlpPath, args...)
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("yt-dlp error: %w", err)
	}

	var m YtManifest
	if err := json.Unmarshal(out, &m); err != nil {
		return nil, fmt.Errorf("json unmarshal error: %w", err)
	}

	return &m, nil
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

	var m *YtManifest
	var err error
	if s.manifestFn != nil {
		m, err = s.manifestFn(r.Context(), videoID)
	} else {
		m, err = s.extractManifest(r.Context(), videoID)
	}
	if err != nil {
		http.Error(w, fmt.Sprintf(`{"error":"failed to resolve manifest: %v"}`, err), http.StatusBadGateway)
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

	// Cache all formats by itag
	s.cacheMu.Lock()
	for _, f := range m.Formats {
		if f.URL != "" && f.FormatID != "" {
			s.cache[videoID+":"+f.FormatID] = &cachedStream{
				directURL: f.URL,
				expiresAt: time.Now().Add(5 * time.Hour),
			}
		}
	}
	s.cacheMu.Unlock()

	// Select best audio (HLS 234 if present, else DASH 140 / 251)
	var bestAudio *YtFormat
	for i, f := range m.Formats {
		if f.VCodec == "none" && f.ACodec != "none" && !strings.Contains(f.FormatID, "drc") {
			if bestAudio == nil {
				bestAudio = &m.Formats[i]
			} else if f.FormatID == "234" {
				bestAudio = &m.Formats[i]
			} else if bestAudio.FormatID != "234" && f.ABR > bestAudio.ABR {
				bestAudio = &m.Formats[i]
			}
		}
	}

	// Select best video stream per height
	heightMap := make(map[int]YtFormat)
	for _, f := range m.Formats {
		if f.VCodec != "none" && f.Height > 0 {
			if existing, ok := heightMap[f.Height]; !ok {
				heightMap[f.Height] = f
			} else if f.FormatID == "312" || f.FormatID == "299" || f.FormatID == "18" {
				heightMap[f.Height] = f
			} else if existing.FormatID != "312" && existing.FormatID != "299" {
				heightMap[f.Height] = f
			}
		}
	}

	var heights []int
	for h := range heightMap {
		heights = append(heights, h)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(heights)))

	var videoStreams []resolveStreamItem
	for _, h := range heights {
		f := heightMap[h]
		videoStreams = append(videoStreams, resolveStreamItem{
			Height: h,
			URL:    fmt.Sprintf("%s/stream/%s?itag=%s", baseURL, videoID, f.FormatID),
		})
	}

	audioURL := ""
	if bestAudio != nil {
		audioURL = fmt.Sprintf("%s/stream/%s?itag=%s", baseURL, videoID, bestAudio.FormatID)
	}

	resp := resolveResponse{
		VideoStreams: videoStreams,
		AudioURL:     audioURL,
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

	itag := r.URL.Query().Get("itag")
	if itag == "" {
		itag = r.URL.Query().Get("format")
	}

	// Look up direct URL in memory cache
	cacheKey := fmt.Sprintf("%s:%s", videoID, itag)
	s.cacheMu.RLock()
	item, found := s.cache[cacheKey]
	s.cacheMu.RUnlock()

	var directURL string
	if found && time.Now().Before(item.expiresAt) {
		directURL = item.directURL
	} else {
		// Populate cache from manifest
		var m *YtManifest
	var err error
	if s.manifestFn != nil {
		m, err = s.manifestFn(r.Context(), videoID)
	} else {
		m, err = s.extractManifest(r.Context(), videoID)
	}
		if err != nil {
			http.Error(w, fmt.Sprintf("failed to extract manifest: %v", err), http.StatusBadGateway)
			return
		}

		s.cacheMu.Lock()
		for _, f := range m.Formats {
			if f.URL != "" && f.FormatID != "" {
				s.cache[videoID+":"+f.FormatID] = &cachedStream{
					directURL: f.URL,
					expiresAt: time.Now().Add(5 * time.Hour),
				}
				if f.FormatID == itag {
					directURL = f.URL
				}
			}
		}
		s.cacheMu.Unlock()
	}

	if directURL == "" {
		http.Error(w, fmt.Sprintf("stream format %s not found", itag), http.StatusNotFound)
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
