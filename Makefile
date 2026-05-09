PREFIX ?= /usr/local/bin

.PHONY: build install uninstall clean

build:
	swiftc ringbridge.swift -o ringbridge

install: build
	cp ringbridge $(PREFIX)/ringbridge

uninstall:
	rm -f $(PREFIX)/ringbridge

clean:
	rm -f ringbridge
