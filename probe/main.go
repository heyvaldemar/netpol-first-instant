// Command probe measures, from inside a pod, when the pod's NetworkPolicy
// takes hold. It has four modes, chosen by its first argument:
//
//	probe  (default) open connections to each target from the process's
//	       first instant, on a fixed schedule, and keep the first one that
//	       answers open to see whether it outlives the policy;
//	once   one attempt per target, for `kubectl exec` on a settled pod;
//	gate   an init container: exit 0 once an allowed destination answers
//	       and a forbidden one does not, exit 1 after a minute;
//	serve  a line echo server, for the in-cluster canary and the runner.
//
// Every time is in milliseconds since the process started, and the start is
// printed as a wall-clock time, so it lines up with the runner's clock (a kind
// node is a container on the runner and shares its clock).
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

var t0 = time.Now()

func ms(t time.Time) float64 { return float64(t.Sub(t0).Microseconds()) / 1000 }

func env(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func envMs(k string, d int) time.Duration {
	if v, err := strconv.Atoi(os.Getenv(k)); err == nil && v > 0 {
		return time.Duration(v) * time.Millisecond
	}
	return time.Duration(d) * time.Millisecond
}

func emit(v any) {
	b, _ := json.Marshal(v)
	fmt.Println(string(b))
}

// A target is name=kind:host:port@interval_ms; kind is "echo" (a line comes
// back from the serve mode) or "http" (an HTTP status line comes back).
type target struct {
	Name     string
	Kind     string
	Addr     string
	Interval time.Duration
}

func parseTargets(s string) ([]target, error) {
	var out []target
	for _, f := range strings.Split(s, ",") {
		f = strings.TrimSpace(f)
		if f == "" {
			continue
		}
		name, rest, ok := strings.Cut(f, "=")
		if !ok {
			return nil, fmt.Errorf("target %q: no name", f)
		}
		spec, every, _ := strings.Cut(rest, "@")
		kind, addr, ok := strings.Cut(spec, ":")
		if !ok || (kind != "echo" && kind != "http") {
			return nil, fmt.Errorf("target %q: kind must be echo or http", f)
		}
		iv := 50
		if every != "" {
			n, err := strconv.Atoi(every)
			if err != nil || n <= 0 {
				return nil, fmt.Errorf("target %q: bad interval", f)
			}
			iv = n
		}
		out = append(out, target{name, kind, addr, time.Duration(iv) * time.Millisecond})
	}
	return out, nil
}

type attempt struct {
	Target  string  `json:"target"`
	StartMs float64 `json:"start_ms"`
	// reply: a full round trip; connected: the handshake completed but no
	// reply came; timeout, refused, unreachable, error: nothing got through.
	Result string  `json:"result"`
	DurMs  float64 `json:"dur_ms"`
	Reply  string  `json:"reply,omitempty"`
	Err    string  `json:"err,omitempty"`
}

func classify(err error) string {
	var ne net.Error
	switch {
	case errors.As(err, &ne) && ne.Timeout():
		return "timeout"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "refused"
	case errors.Is(err, syscall.EHOSTUNREACH), errors.Is(err, syscall.ENETUNREACH):
		return "unreachable"
	}
	return "error"
}

// try opens one connection and asks for one answer. It returns the open
// connection when the answer came back, so the caller may keep it.
func try(tg target, pod string, timeout time.Duration) (attempt, net.Conn) {
	start := time.Now()
	a := attempt{Target: tg.Name, StartMs: ms(start)}
	c, err := net.DialTimeout("tcp", tg.Addr, timeout)
	if err != nil {
		a.Result, a.Err, a.DurMs = classify(err), err.Error(), ms(time.Now())-a.StartMs
		return a, nil
	}
	_ = c.SetDeadline(time.Now().Add(time.Second))
	var req string
	if tg.Kind == "http" {
		host, _, _ := net.SplitHostPort(tg.Addr)
		req = "HEAD / HTTP/1.1\r\nHost: " + host + "\r\nUser-Agent: netpol-first-instant\r\n\r\n"
	} else {
		req = fmt.Sprintf("hi %s %.1f\n", pod, a.StartMs)
	}
	line := ""
	if _, err = c.Write([]byte(req)); err == nil {
		line, err = bufio.NewReader(c).ReadString('\n')
	}
	a.DurMs = ms(time.Now()) - a.StartMs
	if err != nil && line == "" {
		a.Result, a.Err = "connected", err.Error()
		c.Close()
		return a, nil
	}
	a.Result, a.Reply = "reply", strings.TrimSpace(line)
	_ = c.SetDeadline(time.Time{})
	return a, c
}

type ping struct {
	AtMs float64 `json:"at_ms"`
	OK   bool    `json:"ok"`
	Err  string  `json:"err,omitempty"`
}

type hold struct {
	Target      string  `json:"target"`
	Established bool    `json:"established"`
	OpenedAtMs  float64 `json:"opened_at_ms,omitempty"`
	Pings       []ping  `json:"pings"`
}

func probe(pod string) {
	targets, err := parseTargets(env("PROBE_TARGETS", ""))
	if err != nil || len(targets) == 0 {
		fmt.Fprintln(os.Stderr, "PROBE_TARGETS:", err)
		os.Exit(2)
	}
	duration := envMs("PROBE_DURATION_MS", 6000)
	timeout := envMs("PROBE_TIMEOUT_MS", 300)
	holdFor := envMs("PROBE_HOLD_MS", 12000)
	holdName := env("PROBE_HOLD", targets[0].Name)

	var mu sync.Mutex
	var attempts []attempt
	h := hold{Target: holdName, Pings: []ping{}}
	var held net.Conn
	var wg sync.WaitGroup

	for _, tg := range targets {
		wg.Add(1)
		go func(tg target) {
			defer wg.Done()
			var inner sync.WaitGroup
			for next := t0; time.Since(t0) < duration; next = next.Add(tg.Interval) {
				time.Sleep(time.Until(next))
				inner.Add(1)
				go func() {
					defer inner.Done()
					a, c := try(tg, pod, timeout)
					mu.Lock()
					attempts = append(attempts, a)
					if c != nil && tg.Name == holdName && held == nil {
						held, h.Established, h.OpenedAtMs = c, true, a.StartMs
						c = nil
					}
					mu.Unlock()
					if c != nil {
						c.Close()
					}
				}()
			}
			inner.Wait()
		}(tg)
	}

	// The held connection is asked again every quarter second, through the
	// policy taking hold and well after it.
	done := make(chan struct{})
	go func() {
		defer close(done)
		for time.Since(t0) < holdFor {
			time.Sleep(250 * time.Millisecond)
			mu.Lock()
			c := held
			mu.Unlock()
			if c == nil {
				continue
			}
			at := time.Now()
			p := ping{AtMs: ms(at)}
			_ = c.SetDeadline(at.Add(time.Second))
			_, err := fmt.Fprintf(c, "ping %.1f\n", p.AtMs)
			if err == nil {
				_, err = bufio.NewReader(c).ReadString('\n')
			}
			if err != nil {
				p.Err = err.Error()
			} else {
				p.OK = true
			}
			mu.Lock()
			h.Pings = append(h.Pings, p)
			mu.Unlock()
		}
	}()
	wg.Wait()
	<-done
	mu.Lock()
	defer mu.Unlock()
	emit(map[string]any{"event": "result", "pod": pod, "attempts": attempts, "hold": h})
}

func once(pod string) {
	targets, err := parseTargets(env("PROBE_TARGETS", ""))
	if err != nil {
		fmt.Fprintln(os.Stderr, "PROBE_TARGETS:", err)
		os.Exit(2)
	}
	var out []attempt
	for _, tg := range targets {
		a, c := try(tg, pod, envMs("PROBE_TIMEOUT_MS", 1000))
		if c != nil {
			c.Close()
		}
		out = append(out, a)
	}
	emit(map[string]any{"event": "once", "pod": pod, "attempts": out})
}

// gate exits 0 once the allowed destination answers and then the forbidden
// one does not. The order matters: the network is up once the allowed one
// answered, so a refusal after that is the policy, not a network still
// coming up.
func gate(pod string) {
	allow := target{"allow", "echo", env("GATE_ALLOW", ""), 0}
	deny := target{"deny", "echo", env("GATE_DENY", ""), 0}
	if allow.Addr == "" || deny.Addr == "" {
		fmt.Fprintln(os.Stderr, "GATE_ALLOW and GATE_DENY are required")
		os.Exit(2)
	}
	timeout := envMs("GATE_TIMEOUT_MS", 300)
	for tries := 1; time.Since(t0) < time.Minute; tries++ {
		a, c := try(allow, pod, timeout)
		if c != nil {
			c.Close()
		}
		if a.Result == "reply" {
			start := time.Now()
			d, err := net.DialTimeout("tcp", deny.Addr, timeout)
			if err != nil {
				emit(map[string]any{"event": "gate", "pod": pod, "held_at_ms": ms(start), "tries": tries})
				return
			}
			d.Close()
		}
		time.Sleep(100 * time.Millisecond)
	}
	emit(map[string]any{"event": "gate", "pod": pod, "held": false})
	fmt.Fprintln(os.Stderr, "the network policy never took hold")
	os.Exit(1)
}

func serve() {
	ln, err := net.Listen("tcp", env("PROBE_LISTEN", ":8080"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	for {
		c, err := ln.Accept()
		if err != nil {
			continue
		}
		go func(c net.Conn) {
			defer c.Close()
			r := bufio.NewReader(c)
			first := true
			for {
				line, err := r.ReadString('\n')
				if err != nil {
					return
				}
				if first {
					emit(map[string]any{"event": "accept", "unix_ns": time.Now().UnixNano(), "peer": c.RemoteAddr().String(), "line": strings.TrimSpace(line)})
					first = false
				}
				if _, err := fmt.Fprintf(c, "echo %s", line); err != nil {
					return
				}
			}
		}(c)
	}
}

func main() {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-sig; os.Exit(0) }()

	pod := env("POD_NAME", "unknown")
	mode := "probe"
	if len(os.Args) > 1 {
		mode = os.Args[1]
	}
	if mode != "serve" {
		emit(map[string]any{"event": "start", "mode": mode, "pod": pod, "t0_unix_ns": t0.UnixNano()})
	}
	switch mode {
	case "probe":
		probe(pod)
	case "once":
		once(pod)
	case "gate":
		gate(pod)
	case "serve":
		serve()
	case "idle":
		select {}
	default:
		fmt.Fprintln(os.Stderr, "unknown mode", mode)
		os.Exit(2)
	}
}
