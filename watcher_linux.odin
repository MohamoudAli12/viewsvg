#+build linux
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/linux"
import "core:thread"
import "core:time"

// Watches one file for changes on a background thread.
//
// The parent directory is watched rather than the file itself: many editors
// save by writing a temp file and renaming it over the original, which would
// invalidate a watch placed directly on the file's inode.
Watcher :: struct {
	fd:         linux.Fd,
	name:       string, // file name within the watched directory
	thread:     ^thread.Thread,
	// Bumped on every relevant event, with the time of the latest one; the
	// UI reloads once events have been quiet for a moment (see
	// `watcher_poll`), so it doesn't read a file an editor is mid-way
	// through writing.
	generation: u64,
	last_event: i64, // time.Time nanoseconds
	seen:       u64,
}

@(private = "file")
DEBOUNCE :: 100 * time.Millisecond

watcher_start :: proc(w: ^Watcher, path: string) {
	dir, name := os.split_path(path)
	if dir == "" {dir = "."}
	w.name = strings.clone(name)

	fd, err := linux.inotify_init1({.CLOEXEC})
	if err != .NONE {
		fmt.eprintfln("warning: failed to start file watcher: %v", err)
		return
	}
	cdir := strings.clone_to_cstring(dir, context.temp_allocator)
	mask := linux.Inotify_Event_Mask{.MODIFY, .CLOSE_WRITE, .MOVED_TO, .CREATE, .ATTRIB}
	if _, werr := linux.inotify_add_watch(fd, cdir, mask); werr != .NONE {
		fmt.eprintfln("warning: failed to watch %s for changes: %v", dir, werr)
		linux.close(fd)
		return
	}
	w.fd = fd
	w.thread = thread.create_and_start_with_poly_data(w, proc(w: ^Watcher) {
		// Word-backed so each inotify_event header is suitably aligned.
		words: [512]u64
		buf := ([^]u8)(&words)[:size_of(words)]
		for {
			n, err := linux.read(w.fd, buf)
			if err == .EINTR {continue}
			if err != .NONE || n <= 0 {return} // fd closed on shutdown
			for off := 0; off < n; {
				ev := (^linux.Inotify_Event)(&buf[off])
				name_bytes := buf[off + size_of(linux.Inotify_Event):][:ev.len]
				off += size_of(linux.Inotify_Event) + int(ev.len)
				if string(cstring(raw_data(name_bytes))) != w.name {continue}
				sync.atomic_store(&w.last_event, time.now()._nsec)
				sync.atomic_add(&w.generation, 1)
			}
		}
	})
}

// True once per burst of changes, after the file has been quiet for
// `DEBOUNCE`.
watcher_poll :: proc(w: ^Watcher) -> bool {
	gen := sync.atomic_load(&w.generation)
	if gen == w.seen {return false}
	last := time.Time{sync.atomic_load(&w.last_event)}
	if time.since(last) < DEBOUNCE {return false}
	w.seen = gen
	return true
}

watcher_stop :: proc(w: ^Watcher) {
	if w.thread == nil {return}
	// Closing the fd from another thread doesn't reliably interrupt a
	// blocked read(), so the thread is left to die with the process.
	delete(w.name)
}
