packer {
  required_plugins {
    tart = {
      version = ">= 1.12.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type = string
}

source "tart-cli" "tart" {
  vm_name      = var.vm_name
  recovery     = true
  cpu_count    = 8
  memory_gb    = 12
  disk_size_gb = 150
  communicator = "none"
  boot_command = [
    "<wait60s><right><right><enter>",
    "<wait10s><leftAltOn>T<leftAltOff>",
    "<wait10s>csrutil disable<enter>",
    "<wait10s>y<enter>",
    "<wait10s>admin<enter>",
    "<wait10s>halt<enter>"
  ]
}

build {
  sources = ["source.tart-cli.tart"]
}
