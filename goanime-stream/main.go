// goanime-stream resolves a single episode to its direct stream URL using the
// same code path GoAnime's interactive "play online" uses, then launches mpv on
// the URL immediately — nothing is ever written to disk.
//
// It must be built INSIDE the GoAnime module (internal packages), so build.sh
// clones the GoAnime source, drops this file into cmd/goanime-stream/ and runs
// `go build`. The resulting binary is standalone.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"runtime"
	"sort"
	"strconv"
	"strings"

	"github.com/alvarorichard/Goanime/internal/api/providers"
	apisource "github.com/alvarorichard/Goanime/internal/api/source"
	"github.com/alvarorichard/Goanime/internal/appflow"
	"github.com/alvarorichard/Goanime/internal/models"
	"github.com/alvarorichard/Goanime/internal/player"
	"github.com/alvarorichard/Goanime/internal/util"
)

func die(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "goanime-stream: "+format+"\n", a...)
	os.Exit(1)
}

func main() {
	util.InitLogger()

	srcFlag := flag.String("source", "all", "source: all, anidb, animefire, goyabu")
	qualityFlag := flag.String("quality", "best", "quality: best, worst, 1080p, 720p, 480p")
	dryRun := flag.Bool("dry-run", false, "resolve the stream URL and print the mpv command instead of launching mpv")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: goanime-stream [--source all|anidb|animefire|goyabu] [--quality QUALITY] [--dry-run] \"anime name\" EPISODE\n")
	}
	flag.Parse()
	args := flag.Args()
	if len(args) < 2 {
		flag.Usage()
		os.Exit(2)
	}
	query := strings.TrimSpace(args[0])
	episodeNum, err := strconv.Atoi(args[1])
	if err != nil || episodeNum < 1 {
		die("invalid episode number %q", args[1])
	}

	// GlobalQuality is read by the registry stream fetch, exactly like the CLI.
	util.GlobalQuality = *qualityFlag

	var kinds []apisource.SourceKind
	switch strings.ToLower(strings.TrimSpace(*srcFlag)) {
	case "", "all":
		// The panel's sources only — SuperFlix is browser-gated and has
		// interactive flows, so it is never part of headless streaming.
		kinds = []apisource.SourceKind{apisource.AnimeFire, apisource.Goyabu, apisource.AniDB}
	case "animefire":
		kinds = []apisource.SourceKind{apisource.AnimeFire}
	case "goyabu":
		kinds = []apisource.SourceKind{apisource.Goyabu}
	case "anidb":
		kinds = []apisource.SourceKind{apisource.AniDB}
	default:
		die("unknown source %q (use all, anidb, animefire or goyabu)", *srcFlag)
	}

	ctx := context.Background()

	animes, err := providers.SearchAll(ctx, query, kinds...)
	if err != nil {
		die("search failed: %v", err)
	}

	// Try the best-ranked candidates in sequence (up to 5), like a user would
	// in the CLI's result list: an entry with a dead CDN link or broken episode
	// list should not abort the stream — the next match usually plays fine.
	var lastErr error
	attempts := 0
	for _, anime := range rankedAnimes(animes) {
		attempts++
		if attempts > 5 {
			break
		}

		episodes, eerr := appflow.GetAnimeEpisodes(anime)
		if eerr != nil {
			lastErr = fmt.Errorf("%s: %w", anime.Name, eerr)
			continue
		}

		var target *models.Episode
		for i := range episodes {
			n, aerr := strconv.Atoi(player.ExtractEpisodeNumber(episodes[i].Number))
			if aerr == nil && n == episodeNum {
				target = &episodes[i]
				break
			}
		}
		if target == nil {
			lastErr = fmt.Errorf("%s: episode %d not found (available: 1-%d)", anime.Name, episodeNum, len(episodes))
			continue
		}

		anime.Episodes = []models.Episode{*target}

		videoURL, verr := player.GetVideoURLForEpisodeEnhanced(ctx, target, anime)
		if verr != nil {
			lastErr = fmt.Errorf("%s: %w", anime.Name, verr)
			continue
		}

		mpvPath, mpvArgs, merr := mpvCommand(videoURL, anime, episodeNum)
		if merr != nil {
			lastErr = fmt.Errorf("%s: %w", anime.Name, merr)
			continue
		}

		if *dryRun {
			fmt.Printf("anime=%q\nurl=%s\nmpv=%s\nargs=%v\n", anime.Name, videoURL, mpvPath, mpvArgs)
			return
		}

		if perr := runMPV(mpvPath, mpvArgs); perr != nil {
			lastErr = fmt.Errorf("%s: %w", anime.Name, perr)
			continue
		}
		return // mpv played the episode to completion
	}
	die("could not stream %q episode %d: %v", query, episodeNum, lastErr)
}

// rankedAnimes orders search results best-first: Portuguese-tagged titles
// first (the panel defaults to pt-BR), plain titles before season/part/º
// variants, then anonymous results.
func rankedAnimes(animes []*models.Anime) []*models.Anime {
	type scored struct {
		anime *models.Anime
		score int
	}
	all := make([]scored, 0, len(animes))
	for _, a := range animes {
		if a == nil {
			continue
		}
		score := 0
		lower := strings.ToLower(a.Name)
		if strings.Contains(lower, "pt-br") || strings.Contains(lower, "dublado") || strings.Contains(lower, "legendado") {
			score += 2
		}
		if strings.Contains(lower, "todos os idiomas") {
			score--
		}
		if strings.Contains(lower, " season") || strings.Contains(lower, " parte ") || strings.Contains(lower, "º") || strings.Contains(lower, " temporada") {
			score -= 1
		}
		all = append(all, scored{a, score})
	}
	sort.SliceStable(all, func(i, j int) bool { return all[i].score > all[j].score })
	ranked := make([]*models.Anime, 0, len(all))
	for _, sc := range all {
		ranked = append(ranked, sc.anime)
	}
	return ranked
}

// mpvCommand builds the same mpv argument list the CLI uses for online
// playback (network cache, Referer/UA headers, HLS flags, Blogger proxy).
func mpvCommand(videoURL string, anime *models.Anime, episodeNum int) (string, []string, error) {
	mpvPath, err := exec.LookPath("mpv")
	if err != nil {
		return "", nil, errors.New("mpv not found in PATH — install mpv (https://mpv.io/installation/)")
	}

	mpvArgs := []string{
		"--no-terminal",
		"--force-window=yes",
		"--cache=yes",
		"--demuxer-max-bytes=300M",
		"--demuxer-readahead-secs=20",
		"--audio-display=no",
		"--no-config",
		"--hwdec=auto-safe",
		"--vo=gpu",
		"--profile=fast",
		"--video-latency-hacks=yes",
	}
	if runtime.GOOS == "linux" && os.Getenv("WAYLAND_DISPLAY") != "" {
		mpvArgs = append(mpvArgs, "--gpu-context=wayland")
	}

	isHLS := player.LooksLikeHLS(videoURL)
	isBloggerProxy := strings.Contains(videoURL, "127.0.0.1") && strings.Contains(videoURL, "blogger_proxy")

	// Same policy as the CLI (appendPlaybackRefererArgs): only http(s) URLs get
	// a Referer header, and only when the resolver stored one (Goyabu/AnimeFire
	// resolve through a local proxy, so there is none).
	lowerURL := strings.ToLower(strings.TrimSpace(videoURL))
	if strings.HasPrefix(lowerURL, "http://") || strings.HasPrefix(lowerURL, "https://") {
		referer := util.GetGlobalReferer()
		if referer == "" && isHLS {
			referer = "https://streameeeeee.site/"
		}
		if referer != "" {
			mpvArgs = append(mpvArgs, "--http-header-fields=Referer: "+referer)
		}
		if ua := util.GetGlobalUserAgent(); ua != "" {
			mpvArgs = append(mpvArgs, "--user-agent="+ua)
		}
	}
	if isHLS {
		mpvArgs = append(mpvArgs, "--demuxer-lavf-o=allowed_extensions=ALL")
	}
	// googlevideo URLs served through our local Blogger proxy must be fetched
	// directly — the CLI disables yt-dlp for them (playvideo.go).
	if isBloggerProxy {
		mpvArgs = append(mpvArgs, "--ytdl=no")
	}
	if title := mediaTitle(anime, episodeNum); title != "" {
		mpvArgs = append(mpvArgs, "--force-media-title="+title)
	}
	mpvArgs = append(mpvArgs, videoURL)
	return mpvPath, mpvArgs, nil
}

// runMPV launches mpv on the resolved stream URL and waits for it to finish
// (the calling process stays alive so the local stream proxy keeps serving).
func runMPV(mpvPath string, mpvArgs []string) error {
	cmd := exec.Command(mpvPath, mpvArgs...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd.Run()
}

func mediaTitle(anime *models.Anime, episodeNum int) string {
	name := util.SanitizeForDisplayTitle(anime.Name)
	if name == "" {
		return ""
	}
	if anime.MediaType == models.MediaTypeMovie {
		return name
	}
	season := anime.CurrentSeason
	if season < 1 {
		season = 1
	}
	return fmt.Sprintf("%s S%02dE%02d", name, season, episodeNum)
}