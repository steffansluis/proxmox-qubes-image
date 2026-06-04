# Packer QEMU build: drives the unattended Proxmox VE installer ISO headless
# and emits a qcow2. No running Proxmox host required -- the QEMU builder does
# a one-level-deep install, which works on GitHub-hosted runners (KVM when
# available, TCG software emulation otherwise).
#
#   packer init proxmox.pkr.hcl
#   packer build -var "iso_path=prepared.iso" -var "iso_checksum=sha256:..." proxmox.pkr.hcl
#
# `prepared.iso` is the stock Proxmox ISO after `proxmox-auto-install-assistant
# prepare-iso` has embedded answer.toml (see .github/workflows/build.yml).

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1.1"
    }
  }
}

variable "iso_path" {
  type        = string
  description = "Path to the answer-embedded Proxmox installer ISO."
}

variable "iso_checksum" {
  type        = string
  description = "Checksum of the prepared ISO, e.g. 'sha256:abc...' or 'none'."
  default     = "none"
}

variable "accelerator" {
  type        = string
  description = "QEMU accelerator: 'kvm' when /dev/kvm is present, else 'none' (TCG)."
  default     = "kvm"
}

variable "disk_size" {
  type        = string
  description = "Build disk size. Kept small -- root is re-homed on Qubes import."
  default     = "16G"
}

variable "memory" {
  type    = number
  default = 4096
}

variable "cpus" {
  type    = number
  default = 2
}

variable "output_dir" {
  type    = string
  default = "output-proxmox"
}

source "qemu" "proxmox" {
  iso_url      = var.iso_path
  iso_checksum = var.iso_checksum

  # The ISO is already bootable with the embedded answer file; "Automated
  # Installation" auto-selects after a 10s timeout, so no boot_command needed.
  disk_image = false

  accelerator      = var.accelerator
  headless         = true
  machine_type     = "q35"
  cpus             = var.cpus
  memory           = var.memory
  disk_size        = var.disk_size
  disk_interface   = "virtio"
  net_device       = "virtio-net"
  format           = "qcow2"
  output_directory = var.output_dir
  vm_name          = "proxmox-ve.qcow2"

  # No SSH provisioning step: the installer reboots into a power-off (per
  # answer.toml), so we wait on the QEMU process exiting rather than SSH.
  communicator = "none"

  # Expose a QMP control socket so CI can periodically `screendump` the headless
  # console for debugging. Socket lands at <output_dir>/<vm_name>.monitor.
  qmp_enable     = true
  qmp_socket_path = "${var.output_dir}/proxmox-ve.monitor"

  # Generous: a TCG (no-KVM) install can take 45-60 min. Shutdown is the
  # answer-file power-off; Packer detects the QEMU exit.
  shutdown_timeout = "90m"

  # Serial console aids debugging headless installs in CI logs.
  qemuargs = [
    ["-serial", "stdio"],
  ]
}

build {
  sources = ["source.qemu.proxmox"]

  post-processor "checksum" {
    checksum_types = ["sha256"]
    output         = "${var.output_dir}/proxmox-ve.qcow2.{{.ChecksumType}}"
  }
}
