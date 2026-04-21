packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "sequoia-arm64-base"
}

variable "ipsw_url" {
  type    = string
  default = "https://updates.cdn-apple.com/2025WinterFCS/fullrestores/072-08269/7CAAB9F7-E970-428D-8764-4CD7BCD105CD/UniversalMac_15.3_24D60_Restore.ipsw"
}

source "tart-cli" "create-base" {
  from_ipsw    = var.ipsw_url
  vm_name      = var.vm_name
  cpu_count    = 8
  memory_gb    = 12
  disk_size_gb = 150
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "300s"

  boot_command = [
    "<wait60s><spacebar>",
    "<wait30s>italiano<esc>english<enter>",
    "<wait30s>united states<leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><tab><tab><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s>admin<tab><tab>admin<tab>admin<tab><tab><tab><spacebar>",
    "<wait120s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><tab><tab>UTC<enter><leftShiftOn><tab><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><tab><spacebar>",
    "<wait10s><tab><spacebar><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><leftShiftOn><tab><leftShiftOff><spacebar>",
    "<wait10s><spacebar>",
    "<wait10s><leftAltOn><spacebar><leftAltOff>Terminal<enter>",
    "<wait10s>defaults write NSGlobalDomain AppleKeyboardUIMode -int 3<enter>",
    "<wait10s><leftAltOn>q<leftAltOff>",
    "<wait10s><leftAltOn><spacebar><leftAltOff>System Settings<enter>",
    "<wait10s><leftAltOn>f<leftAltOff>sharing<enter>",
    "<wait10s><tab><tab><tab><tab><tab><spacebar>",
    "<wait10s><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><tab><spacebar>",
    "<wait10s><leftAltOn>q<leftAltOff>",
  ]

  create_grace_time  = "30s"
  recovery_partition = "keep"
}

build {
  name    = "create-base-image"
  sources = ["source.tart-cli.create-base"]

  provisioner "shell" {
    inline = [
      "echo 'Enabling passwordless sudo...'",
      "echo admin | sudo -S sh -c 'mkdir -p /etc/sudoers.d/ && echo \"admin ALL=(ALL) NOPASSWD: ALL\" | tee /etc/sudoers.d/admin-nopasswd'",
      "echo 'Base image ready.'",
    ]
  }
}
