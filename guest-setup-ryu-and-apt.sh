#!/usr/bin/env bash
# guest-setup-ryu-and-apt.sh
#
# Run this INSIDE the Mininet VM (e.g. over SSH):
#   ssh -p 2222 mininet@localhost
#   ./guest-setup-ryu-and-apt.sh
#
# Fixes:
#   1. apt failing on plain HTTP mirrors (network path resets port-80
#      HTTP but HTTPS works fine) -> switch sources.list to HTTPS.
#   2. Installs Ryu via pip with dependency versions compatible with
#      this VM's stock Python 3.6 (newer netaddr/eventlet releases
#      dropped 3.6 support and break ryu-manager).

set -euo pipefail

echo "== Fixing apt: switching mirrors from HTTP to HTTPS =="
sudo cp /etc/apt/sources.list /etc/apt/sources.list.bak
sudo sed -i 's|http://|https://|g' /etc/apt/sources.list
sudo apt install -y apt-transport-https || true
sudo apt update

echo
echo "== Ensuring ~/.local/bin is on PATH (pip --user installs land here) =="
if ! grep -q '.local/bin' ~/.bashrc; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
fi
export PATH="$HOME/.local/bin:$PATH"

echo
echo "== Installing Ryu with Python-3.6-compatible dependency pins =="
pip3 install --user ryu
pip3 install --user "netaddr==0.8.0"
pip3 install --user "eventlet==0.30.2"

echo
echo "== Verifying installation =="
ryu-manager --version

cat <<'EOF'

Done. To try it out, open two terminals (SSH sessions) into this VM:

  Terminal 1 (controller):
    ryu-manager ryu.app.simple_switch_13

  Terminal 2 (Mininet topology):
    sudo mn --topo single,3 --controller=remote,ip=127.0.0.1,port=6653

  Then at the mininet> prompt:
    pingall

  Inspect the flow table OpenFlow actually installed:
    sudo ovs-ofctl dump-flows s1
EOF
