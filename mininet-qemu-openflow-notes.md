# Mininet on QEMU + First OpenFlow Lab — Setup Log

Goal: run the official Mininet VM (distributed as `.ovf` + `.vmdk`, normally
for VirtualBox/VMware) under QEMU instead, then get a real OpenFlow
controller (Ryu) driving the switch, as groundwork before moving on to P4.

Host: Ubuntu, Intel CPU (VT-x), 8 cores.
Guest: Ubuntu 18.04.5 (Mininet 2.3.0 official VM image), Python 3.6.9.

---

## 1. Host setup: KVM + QEMU

**Check CPU virtualization support:**
```bash
egrep -c '(vmx|svm)' /proc/cpuinfo
```
Non-zero = supported.

**Problem:** `/dev/kvm` didn't exist even though the CPU supported
virtualization (`vmx` present, 8 cores reporting it).

**Cause:** the `kvm_intel` kernel module simply wasn't loaded yet.

**Fix:**
```bash
sudo modprobe kvm_intel
ls -l /dev/kvm     # now exists, owned by root:kvm
sudo usermod -aG kvm $USER
```
Group membership only applies to a *new* login session — needed a
logout/login (or `sg kvm -c "..."` as a one-off workaround) before QEMU
could use `/dev/kvm` without a permissions error.

**QEMU was already installed** (`qemu-system-x86_64 --version` → 8.2.2),
so no install step was needed on this host.

---

## 2. Converting the VMDK to qcow2

The Mininet VM ships as a zip containing `.ovf` (XML hardware descriptor)
and `.vmdk` (disk image). QEMU doesn't consume `.ovf` directly, but reading
it confirmed the original spec: **1 vCPU, 1024 MB RAM, 8 GB disk.**

```bash
qemu-img convert -f vmdk -O qcow2 mininet-vm-x86_64.vmdk mininet.qcow2
```

## 3. Launching the VM

```bash
qemu-system-x86_64 \
  -enable-kvm -m 2048 -smp 2 \
  -drive file=mininet.qcow2,format=qcow2 \
  -netdev user,id=n1,hostfwd=tcp::2222-:22 \
  -device e1000,netdev=n1 \
  -display gtk
```
(RAM/vCPU bumped above the original 1024MB/1vCPU spec since the host had
headroom to spare.)

**Default VM credentials:** `mininet` / `mininet`

Once booted, SSH in (cleaner than the console window):
```bash
ssh -p 2222 mininet@localhost
```

---

## 4. Basic Mininet sanity check

```bash
mininet@mininet-vm:~$ sudo mn
mininet> pingall
*** Results: 0% dropped (2/2 received)
```
Confirmed: QEMU networking, SSH, and Mininet's default topology all work.

**Minor gotcha:** `python -m http.server 80 &` failed with
`No module named http` — the VM's `python` points to **Python 2**, and
`http.server` is Python-3-only. Fixed by calling `python3` explicitly.
Also: killing background jobs by `%jobname` doesn't work reliably through
Mininet's node-exec wrapper — use `pkill -f <process>` instead.

---

## 5. Installing Ryu (OpenFlow controller)

**Problem 1 — apt couldn't install `python3-ryu`:**
Every apt HTTP request to `archive.ubuntu.com` / `security.ubuntu.com`
failed with `Connection failed` or (after further digging)
`Connection reset by peer` right after the request was sent.

**Diagnosis:**
```bash
wget -v https://arvancloud.ir        # worked fine (HTTPS)
wget -v http://archive.ubuntu.com    # connected, then reset in headers
```
HTTPS worked perfectly; plain port-80 HTTP got reset mid-request. This
pointed to something on the network path interfering with unencrypted
HTTP specifically (not a QEMU/slirp issue, not DNS, not routing — the TCP
handshake succeeded every time).

**Fix — switch apt to HTTPS mirrors:**
```bash
sudo sed -i 's|http://|https://|g' /etc/apt/sources.list
sudo apt install apt-transport-https
sudo apt update
```
This fixed apt generally, though by this point Ryu was already being
installed a different way (see below).

**Problem 2 — `pip3 install ryu` succeeded but `ryu-manager` wasn't found:**
`pip3 install --user ryu` reported success, but `ryu-manager --version`
returned "command not found."

**Cause:** pip installs user-scope console scripts to `~/.local/bin`,
which wasn't on `$PATH`.

**Fix:**
```bash
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

**Problem 3 — `RuntimeError: Python 3.7.0 or higher is required!`**
Once found, `ryu-manager` crashed on import because pip pulled the latest
`netaddr` (1.0.0), which dropped support for the VM's Python 3.6.

**Fix:** pin an older, 3.6-compatible netaddr:
```bash
pip3 install --user "netaddr==0.8.0"
```

**Problem 4 — `ImportError: cannot import name 'ALREADY_HANDLED'`**
Next failure: Ryu's WSGI app imports `ALREADY_HANDLED` from
`eventlet.wsgi`, which newer eventlet releases removed.

**Fix:** pin an older eventlet:
```bash
pip3 install --user "eventlet==0.30.2"
```

After this, `ryu-manager --version` finally returned `ryu-manager 4.34`
cleanly.

> **Context:** Ryu itself is effectively unmaintained upstream, while its
> dependencies (eventlet, netaddr, oslo.*) keep shipping breaking changes.
> Installing it fresh via pip today reliably means hitting exactly this
> kind of version-pinning whack-a-mole — finite, but expect 1-2 rounds of it.

---

## 6. First working OpenFlow test

**Terminal 1 — controller:**
```bash
ryu-manager ryu.app.simple_switch_13
```

**Terminal 2 — Mininet pointed at the controller:**
```bash
sudo mn --topo single,3 --controller=remote,ip=127.0.0.1,port=6653
mininet> pingall
```
Result: `0% dropped (6/6 received)`, and Ryu's terminal logged live
`packet in` events for each host's traffic — confirming the switch has
no local learning logic; the controller is doing all of it.

**Inspecting the real flow table installed via OpenFlow:**
```bash
sudo ovs-ofctl dump-flows s1
```
Showed the exact match/action entries Ryu pushed (source/dest MAC +
in_port matches, `output:<port>` actions), plus the default
`actions=CONTROLLER:65535` catch-all rule for anything unmatched.

---

## 7. Giving the Mininet *hosts* internet access

Note: the VM itself already had internet (that's how pip/apt worked at
all) — but Mininet's virtual hosts (h1, h2, h3) live in their own
isolated network namespaces behind the OVS switch and have no path out
by default.

**Fix — Mininet's built-in NAT flag:**
```bash
sudo mn --topo single,3 --controller=remote,ip=127.0.0.1,port=6653 --nat
```
This adds a NAT node, sets up `iptables` MASQUERADE, and configures
default routes on the hosts automatically.

---

## Current working setup, end to end

```bash
# Host:
qemu-system-x86_64 -enable-kvm -m 2048 -smp 2 \
  -drive file=mininet.qcow2,format=qcow2 \
  -netdev user,id=n1,hostfwd=tcp::2222-:22 \
  -device e1000,netdev=n1 -display gtk

# Guest, terminal 1:
ryu-manager ryu.app.simple_switch_13

# Guest, terminal 2:
sudo mn --topo single,3 --controller=remote,ip=127.0.0.1,port=6653 --nat
mininet> pingall

# Guest, terminal 3 (optional inspection):
sudo ovs-ofctl dump-flows s1
```

## Next planned step

Modify `simple_switch_13.py` to add a custom rule that explicitly
**drops** traffic matching a chosen field (e.g. a specific IP or TCP
port), confirm it in `ovs-ofctl dump-flows`, and confirm the drop with a
failing `pingall`/`h1 ping h2` — the first hands-on step toward writing
real OpenFlow logic instead of just using the stock learning-switch app.

After that: install the P4 toolchain (`p4c` + BMv2/`simple_switch`) via
the `p4lang/tutorials` repo, likely requiring a disk resize
(`qemu-img resize mininet.qcow2 +20G`) since building protobuf/gRPC/BMv2
from source needs more room than the original 8GB image has spare.
