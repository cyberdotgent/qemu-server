PACKAGE ?= qemu-server
DESTDIR=
PREFIX=/usr
LIBDIR=$(DESTDIR)/$(PREFIX)/lib
LIBEXECDIR=$(DESTDIR)/$(PREFIX)/libexec/$(PACKAGE)
LIBSYSTEMDDIR := $(DESTDIR)/usr/lib/systemd
DBUSDIR := $(DESTDIR)/usr/share/dbus-1
SHAREDIR=$(DESTDIR)/$(PREFIX)/share/$(PACKAGE)

.PHONY: install
install: 3270-sessions 3270-tmux.conf pve-qemu-3270@.service sclplm-hardcopy pve-qemu-sclplm@.service pve-usb.cfg pve-q35.cfg pve-q35-4.0.cfg bootsplash.jpg modules-load.conf pve-bridge pve-bridge-hotplug pve-bridgedown
	install -d $(SHAREDIR)
	install -m 0644 pve-usb.cfg $(SHAREDIR)
	install -m 0644 pve-q35.cfg $(SHAREDIR)
	install -m 0644 pve-q35-4.0.cfg $(SHAREDIR)
	install -m 0644 -D bootsplash.jpg $(SHAREDIR)
	install -m 0644 3270-tmux.conf $(SHAREDIR)
	install -D -m 0644 modules-load.conf $(LIBDIR)/modules-load.d/qemu-server.conf
	install -d $(LIBEXECDIR)
	install -m 0755 pve-bridge $(LIBEXECDIR)/pve-bridge
	install -m 0755 pve-bridge-hotplug $(LIBEXECDIR)/pve-bridge-hotplug
	install -m 0755 pve-bridgedown $(LIBEXECDIR)/pve-bridgedown
	install -D -m 0755 dbus-vmstate $(LIBEXECDIR)/dbus-vmstate
	install -m 0755 3270-sessions $(LIBEXECDIR)/3270-sessions
	install -m 0755 sclplm-hardcopy $(LIBEXECDIR)/sclplm-hardcopy
	install -d $(LIBSYSTEMDDIR)
	install -D -m 0644 pve-dbus-vmstate@.service $(LIBSYSTEMDDIR)/system/pve-dbus-vmstate@.service
	install -m 0644 pve-qemu-3270@.service $(LIBSYSTEMDDIR)/system/pve-qemu-3270@.service
	install -m 0644 pve-qemu-sclplm@.service $(LIBSYSTEMDDIR)/system/pve-qemu-sclplm@.service
	install -d $(DBUSDIR)
	install -D -m 0644 org.qemu.VMState1.conf $(DBUSDIR)/system.d/org.qemu.VMState1.conf

.PHONY: clean
clean:
