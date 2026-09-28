ODIN   ?= odin
PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

BIN     := svgview
SOURCES := $(wildcard *.odin svg/*.odin)

.PHONY: all test install uninstall clean

all: $(BIN)

$(BIN): $(SOURCES)
	$(ODIN) build . -out:$(BIN) -o:speed -vet

test:
	$(ODIN) test svg -vet
	$(ODIN) test . -vet

install: $(BIN)
	install -Dm755 $(BIN) $(BINDIR)/$(BIN)

uninstall:
	rm -f $(BINDIR)/$(BIN)

clean:
	rm -f $(BIN)
