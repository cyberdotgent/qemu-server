DESTDIR=
PREFIX=/usr
PERLDIR=$(PREFIX)/share/perl5

SOURCES=Agent.pm	\
	Blockdev.pm	\
	BlockJob.pm	\
	Cfg2Cmd.pm	\
	CCW.pm		\
	CGroup.pm	\
	Console3270.pm	\
	Cloudinit.pm	\
	CPUConfig.pm	\
	CPUFlags.pm	\
	DASD.pm		\
	DBusVMState.pm	\
	Drive.pm	\
	DriveDevice.pm	\
	Helpers.pm	\
	ImportDisk.pm	\
	IPL.pm		\
	Netboot.pm	\
	Machine.pm	\
	Memory.pm	\
	MetaInfo.pm	\
	Monitor.pm	\
	Network.pm	\
	OVA.pm		\
	OVMF.pm		\
	PCI.pm		\
	QemuImage.pm	\
	QMPHelpers.pm	\
	QSD.pm		\
	RNG.pm		\
	RunState.pm	\
	SclpLog.pm	\
	Snapshot.pm	\
	StateFile.pm	\
	Tape.pm		\
	USB.pm		\
	Virtiofs.pm	\
	VolumeChain.pm

.PHONY: install
install: $(SOURCES)
	for i in $(SOURCES); do install -D -m 0644 $$i $(DESTDIR)$(PERLDIR)/PVE/QemuServer/$$i; done
	$(MAKE) -C Cfg2Cmd install
	$(MAKE) -C PCI install
