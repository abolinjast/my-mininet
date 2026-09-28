#!/usr/bin/env bash
# host-setup-qemu-mininet.sh
#
# Run this on your HOST machine (Ubuntu), NOT inside the Mininet VM.
# It checks/enables KVM acceleration, verifies QEMU is installed,
# converts the Mininet .vmdk to .qcow2, and prints the launch command.
#
# Usage: ./host-setup-qemu-mininet.sh /path/to/mininet-vm-x86_64.vmdk

set -euo pipefail

VMDK_FILE="${1:-}"
QCOW2_FILE="mininet.qcow2"
RAM_MB=2048
SMP=2
SSH_PORT=2222

if [[ -z "$VMDK_FILE" ]]; then
  echo "Usage: $0 <path-to-vmdk-file>"
  exit 1
fi

echo "== Checking CPU virtualization support =="
if ! egrep -q '(vmx|svm)' /proc/cpuinfo; then
  echo "CPU does not report vmx/svm flags. Hardware virtualization may not be supported."
  exit 1
fi
echo "OK: CPU supports hardware virtualization."

echo
echo "== Checking / loading KVM kernel module =="
if ! lsmod | grep -q kvm; then
  if grep -q vmx /proc/cpuinfo; then
    echo "Intel CPU detected, loading kvm_intel..."
    sudo modprobe kvm_intel
  else
    echo "AMD CPU detected, loading kvm_amd..."
    sudo modprobe kvm_amd
  fi
fi
lsmod | grep kvm

if [[ ! -e /dev/kvm ]]; then
  echo "ERROR: /dev/kvm still missing."
  echo "Check dmesg for 'disabled by bios' and enable VT-x/AMD-V in your"
  echo "BIOS/UEFI (usually under Advanced > CPU Configuration), then reboot."
  exit 1
fi
echo "OK: /dev/kvm is present."

echo
echo "== Ensuring current user is in the kvm group =="
if ! groups | grep -qw kvm; then
  sudo usermod -aG kvm "$USER"
  echo "Added $USER to the kvm group."
  echo "NOTE: this only takes effect in a NEW login session (log out/in, or reboot)."
  echo "To use KVM right now without logging out, wrap qemu with: sg kvm -c \"...\""
else
  echo "OK: $USER is already in the kvm group."
fi

echo
echo "== Checking QEMU installation =="
if ! command -v qemu-system-x86_64 &>/dev/null; then
  echo "qemu-system-x86_64 not found. Install it first, e.g.:"
  echo "  sudo apt update && sudo apt install qemu-system-x86 qemu-utils"
  exit 1
fi
qemu-system-x86_64 --version
if ! command -v qemu-img &>/dev/null; then
  echo "qemu-img not found. Install qemu-utils:"
  echo "  sudo apt install qemu-utils"
  exit 1
fi

echo
echo "== Converting VMDK to qcow2 (skipped if already done) =="
if [[ ! -f "$QCOW2_FILE" ]]; then
  qemu-img convert -f vmdk -O qcow2 "$VMDK_FILE" "$QCOW2_FILE"
  echo "Created $QCOW2_FILE"
else
  echo "$QCOW2_FILE already exists, skipping conversion."
fi

CMD="qemu-system-x86_64 -enable-kvm -m $RAM_MB -smp $SMP -drive file=$QCOW2_FILE,format=qcow2 -netdev user,id=n1,hostfwd=tcp::${SSH_PORT}-:22 -device e1000,netdev=n1 -display gtk"

echo
echo "=========================================================="
echo "Setup complete. Launch the VM with:"
echo
echo "  $CMD"
echo
echo "If your shell doesn't have 'kvm' group membership active yet, use:"
echo
echo "  sg kvm -c \"$CMD\""
echo
echo "Once booted, log in at the console (mininet/mininet) or SSH in:"
echo
echo "  ssh -p $SSH_PORT mininet@localhost"
echo "=========================================================="
