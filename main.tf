terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.100"
    }

    azapi = {
      source  = "Azure/azapi"
      version = "~> 1.13"
    }

    random = {
      source = "hashicorp/random"
    }
  }
}

provider "azurerm" {
  features {}
}

############################
# VARIABLES
############################

variable "location" {
  default = "eastus2"
}

variable "prefix" {
  default = "nwlab"
}

variable "admin_username" {
  default = "azureuser"
}

variable "ssh_public_key" {
  description = "Your SSH public key"
}

variable "homelab_public_ip" {
  description = "Public IP of your homelab machine for hybrid path monitoring (leave empty to skip)"
  default     = ""
}

############################
# RESOURCE GROUP
############################

resource "azurerm_resource_group" "rg" {
  name     = "${var.prefix}-rg"
  location = var.location
}

############################
# NETWORK
############################

resource "azurerm_virtual_network" "vnet" {
  name                = "${var.prefix}-vnet"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.0.0.0/16"]
}

resource "azurerm_subnet" "frontend" {
  name                 = "frontend-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_subnet" "backend" {
  name                 = "backend-subnet"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.0.2.0/24"]
}

############################
# NSGs
############################

resource "azurerm_network_security_group" "frontend_nsg" {
  name                = "${var.prefix}-frontend-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "104.12.106.70/32"
    destination_port_range     = "22"
    source_port_range          = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "backend_nsg" {
  name                = "${var.prefix}-backend-nsg"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  security_rule {
    name                       = "allow-http-from-frontend"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_address_prefix      = "10.0.1.0/24"
    destination_port_range     = "80"
    source_port_range          = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "frontend_assoc" {
  subnet_id                 = azurerm_subnet.frontend.id
  network_security_group_id = azurerm_network_security_group.frontend_nsg.id
}

resource "azurerm_subnet_network_security_group_association" "backend_assoc" {
  subnet_id                 = azurerm_subnet.backend.id
  network_security_group_id = azurerm_network_security_group.backend_nsg.id
}

############################
# STORAGE
############################

resource "random_string" "rand" {
  length  = 5
  special = false
  upper   = false
}

resource "azurerm_storage_account" "diag" {
  name                     = "${var.prefix}diag${random_string.rand.result}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

############################
# PUBLIC IP (Standard SKU)
############################

resource "azurerm_public_ip" "vm1_ip" {
  name                = "${var.prefix}-vm1-ip"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  allocation_method = "Static"
  sku               = "Standard"
}

############################
# NICs
############################

resource "azurerm_network_interface" "vm1_nic" {
  name                = "${var.prefix}-vm1-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.frontend.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.vm1_ip.id
  }
}

resource "azurerm_network_interface" "vm2_nic" {
  name                = "${var.prefix}-vm2-nic"
  location            = var.location
  resource_group_name = azurerm_resource_group.rg.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.backend.id
    private_ip_address_allocation = "Dynamic"
  }
}

############################
# VM1 (Frontend - Spot)
############################

resource "azurerm_linux_virtual_machine" "vm1" {
  name                = "${var.prefix}-vm1"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  size                = "Standard_D2s_v3"

#  priority        = "Spot"
#  eviction_policy = "Deallocate"
  max_bid_price   = -1

  admin_username = var.admin_username

  identity {
    type = "SystemAssigned"
  }

  network_interface_ids = [azurerm_network_interface.vm1_nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<EOF
#!/bin/bash
apt update
apt install -y nginx iperf3 tcpdump curl netcat
systemctl enable nginx
systemctl start nginx
EOF
  )
}

############################
# VM2 (Backend - Spot)
############################

resource "azurerm_linux_virtual_machine" "vm2" {
  name                = "${var.prefix}-vm2"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  size                = "Standard_D2s_v3"

#  priority        = "Spot"
#  eviction_policy = "Deallocate"
  max_bid_price   = -1

  admin_username = var.admin_username

  identity {
    type = "SystemAssigned"
  }

  network_interface_ids = [azurerm_network_interface.vm2_nic.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts"
    version   = "latest"
  }

  custom_data = base64encode(<<EOF
#!/bin/bash
apt update
apt install -y nginx iperf3 tcpdump curl netcat
systemctl enable nginx
systemctl start nginx
EOF
  )
}


############################
# OUTPUT
############################

output "vm1_public_ip" {
  value = azurerm_public_ip.vm1_ip.ip_address
}

data "azurerm_network_watcher" "nw" {
  name                = "NetworkWatcher_${var.location}"
  resource_group_name = "nwlab-rg"
}


resource "azurerm_log_analytics_workspace" "law" {
  name                = "nwlab-law"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
}


resource "azurerm_log_analytics_solution" "traffic_analytics" {
  solution_name         = "NetworkMonitoring"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  workspace_resource_id = azurerm_log_analytics_workspace.law.id
  workspace_name        = azurerm_log_analytics_workspace.law.name

  plan {
    publisher = "Microsoft"
    product   = "OMSGallery/NetworkMonitoring"
  }
}

resource "azapi_resource" "vnet_flow_logs" {
  type      = "Microsoft.Network/networkWatchers/flowLogs@2023-11-01"
  name      = "vnet-flow-log"
  #parent_id = azurerm_network_watcher.nw.id
  parent_id = data.azurerm_network_watcher.nw.id

  location  = data.azurerm_network_watcher.nw.location  # 👈 REQUIRED
  
  body = jsonencode({
    properties = {
      targetResourceId = azurerm_virtual_network.vnet.id

      #storageId = azurerm_storage_account.flowlogs.id
      storageId = azurerm_storage_account.diag.id

      enabled = true

      retentionPolicy = {
        enabled = true
        days    = 7
      }

      format = {
        type    = "JSON"
        version = 2
      }

      flowAnalyticsConfiguration = {
        networkWatcherFlowAnalyticsConfiguration = {
          enabled = true

          workspaceId         = azurerm_log_analytics_workspace.law.workspace_id
          workspaceRegion     = azurerm_log_analytics_workspace.law.location
          workspaceResourceId = azurerm_log_analytics_workspace.law.id

          trafficAnalyticsInterval = 60
        }
      }
    }
  })
}

############################
# AZURE MONITOR AGENT (AMA)
############################

resource "azurerm_virtual_machine_extension" "vm1_ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm1.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_virtual_machine_extension" "vm2_ama" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm2.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
}

resource "azurerm_monitor_data_collection_rule" "dcr" {
  name                = "${var.prefix}-dcr"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.law.id
      name                  = "law-destination"
    }
  }

  data_flow {
    streams      = ["Microsoft-Perf", "Microsoft-Syslog"]
    destinations = ["law-destination"]
  }

  data_sources {
    performance_counter {
      name                          = "perf-counters"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "\\Processor Information(_Total)\\% Processor Time",
        "\\Processor Information(_Total)\\% User Time",
        "\\Processor Information(_Total)\\% Privileged Time",
        "\\Memory\\Available MBytes",
        "\\Memory\\% Committed Bytes In Use",
        "\\LogicalDisk(*)\\% Free Space",
        "\\LogicalDisk(*)\\Avg. Disk sec/Read",
        "\\LogicalDisk(*)\\Avg. Disk sec/Write",
        "\\LogicalDisk(*)\\Disk Read Bytes/sec",
        "\\LogicalDisk(*)\\Disk Write Bytes/sec",
        "\\Network Interface(*)\\Bytes Received/sec",
        "\\Network Interface(*)\\Bytes Sent/sec",
      ]
    }

    syslog {
      name           = "syslog-source"
      streams        = ["Microsoft-Syslog"]
      facility_names = ["auth", "authpriv", "cron", "daemon", "kern", "syslog", "user"]
      log_levels     = ["Warning", "Error", "Critical", "Alert", "Emergency"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "vm1_dcr" {
  name                    = "vm1-dcr-assoc"
  target_resource_id      = azurerm_linux_virtual_machine.vm1.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.dcr.id
}

resource "azurerm_monitor_data_collection_rule_association" "vm2_dcr" {
  name                    = "vm2-dcr-assoc"
  target_resource_id      = azurerm_linux_virtual_machine.vm2.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.dcr.id
}

############################
# CONNECTION MONITOR
############################

resource "azurerm_virtual_machine_extension" "vm1_nw_agent" {
  name                       = "NetworkWatcherAgentLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm1.id
  publisher                  = "Microsoft.Azure.NetworkWatcher"
  type                       = "NetworkWatcherAgentLinux"
  type_handler_version       = "1.4"
  auto_upgrade_minor_version = true
}

resource "azurerm_virtual_machine_extension" "vm2_nw_agent" {
  name                       = "NetworkWatcherAgentLinux"
  virtual_machine_id         = azurerm_linux_virtual_machine.vm2.id
  publisher                  = "Microsoft.Azure.NetworkWatcher"
  type                       = "NetworkWatcherAgentLinux"
  type_handler_version       = "1.4"
  auto_upgrade_minor_version = true
}

resource "azurerm_network_connection_monitor" "cm" {
  name               = "${var.prefix}-connection-monitor"
  network_watcher_id = data.azurerm_network_watcher.nw.id
  location           = var.location

  endpoint {
    name               = "vm1-frontend"
    target_resource_id = azurerm_linux_virtual_machine.vm1.id
  }

  endpoint {
    name               = "vm2-backend"
    target_resource_id = azurerm_linux_virtual_machine.vm2.id
  }

  dynamic "endpoint" {
    for_each = var.homelab_public_ip != "" ? [var.homelab_public_ip] : []
    content {
      name    = "homelab"
      address = endpoint.value
    }
  }

  test_configuration {
    name                      = "tcp-80"
    protocol                  = "Tcp"
    test_frequency_in_seconds = 30
    tcp_configuration {
      port = 80
    }
  }

  test_configuration {
    name                      = "icmp"
    protocol                  = "Icmp"
    test_frequency_in_seconds = 30
    icmp_configuration {
      trace_route_enabled = true
    }
  }

  test_group {
    name                     = "frontend-to-backend"
    source_endpoints         = ["vm1-frontend"]
    destination_endpoints    = ["vm2-backend"]
    test_configuration_names = ["tcp-80", "icmp"]
  }

  dynamic "test_group" {
    for_each = var.homelab_public_ip != "" ? [1] : []
    content {
      name                     = "vm1-to-homelab"
      source_endpoints         = ["vm1-frontend"]
      destination_endpoints    = ["homelab"]
      test_configuration_names = ["icmp"]
    }
  }

  output_workspace_resource_ids = [azurerm_log_analytics_workspace.law.id]

  depends_on = [
    azurerm_virtual_machine_extension.vm1_nw_agent,
    azurerm_virtual_machine_extension.vm2_nw_agent,
  ]
}
