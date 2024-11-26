locals {
  vpc_connector_name = "${var.name}-ac"
}

# Networking: VPC

resource "google_compute_network" "datomic_vpc" {
  provider = google-beta
  project = var.project_id
  name = "${var.name}-network"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "datomic_subnet" {
  provider = google-beta
  project = var.project_id
  name = "${var.name}-subnet"
  ip_cidr_range = "10.0.0.0/28"
  network = google_compute_network.datomic_vpc.id
}

# VPC Access connector

resource "google_project_service" "vpcaccess" {
  provider = google-beta
  project = var.project_id
  service = "vpcaccess.googleapis.com"
  disable_on_destroy = false

  timeouts {
    create = "10m"
    delete = "10m"
  }
}

resource "google_vpc_access_connector" "datomic_access_connector" {
  provider = google-beta
  project = var.project_id
  region = var.region
  name = local.vpc_connector_name
  min_instances = 2
  max_instances = 3
  subnet {
    name = google_compute_subnetwork.datomic_subnet.name
  }
}

# Datomic service account

resource "google_service_account" "datomic_sa" {
  project = var.project_id
  account_id = "${var.name}-sa"
}

resource "google_project_iam_member" "secretmanager_access" {
  project = var.project_id
  role = "roles/secretmanager.secretAccessor"
  member = "serviceAccount:${google_service_account.datomic_sa.email}"
}

resource "google_project_iam_member" "secretmanager_viewer" {
  project = var.project_id
  role = "roles/secretmanager.viewer"
  member = "serviceAccount:${google_service_account.datomic_sa.email}"
}

resource "google_project_iam_member" "compute_viewer" {
  project = var.project_id
  role = "roles/compute.viewer"
  member = "serviceAccount:${google_service_account.datomic_sa.email}"
}

# Datomic VM instance

resource "google_compute_address" "datomic_server_ip" {
  project = var.project_id
  region = var.region
  name = "${var.name}-ip"
  address_type = "INTERNAL"
  subnetwork = google_compute_subnetwork.datomic_subnet.self_link
}

resource "google_compute_disk" "disk" {
  project = var.project_id
  name = "${var.name}-data-disk"
  type = "pd-ssd"
  zone = "${var.region}-a"
  size = var.ssd_size
}

resource "google_compute_instance" "datomic_server" {
  project = var.project_id

  labels = {
    server = "datomic"
  }

  name = "${var.name}-vm"
  machine_type = var.vm_machine_type
  zone = "${var.region}-${var.zone}"

  tags = ["datomic-server"]

  metadata = {
    enable-oslogin = "TRUE"
    enable-osconfig = "TRUE"
    enable-guest-attributes = "TRUE"
  }

  min_cpu_platform = "AUTOMATIC"

  scheduling {
    on_host_maintenance = "MIGRATE"
  }

  boot_disk {
    initialize_params {
      image = "ubuntu-minimal-2204-jammy-v20230918"
      labels = {
        os = "ubuntu"
      }
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.datomic_subnet.self_link
    network_ip = google_compute_address.datomic_server_ip.address
  }

  service_account {
    email = google_service_account.datomic_sa.email
    scopes = [
      "userinfo-email",
      "compute-ro",
      "storage-ro",
      "cloud-platform"
    ]
  }

  attached_disk {
    source = google_compute_disk.disk.self_link
    device_name = "datomic-data-disk"
    mode = "READ_WRITE"
  }

  metadata_startup_script = <<EOT
#!/bin/bash

# Ensure the disk is formatted (only needed for a new disk)
if ! lsblk | grep -q "datomic-data-disk"; then
  mkfs.ext4 -F /dev/disk/by-id/google-datomic-data-disk
fi

# Create a directory for mounting
mkdir -p /mnt/data

# Add to /etc/fstab if not already present for future reboots
if ! grep -q "/dev/disk/by-id/google-datomic-data-disk /mnt/data" /etc/fstab; then
  echo "/dev/disk/by-id/google-datomic-data-disk /mnt/data ext4 defaults 0 0" >> /etc/fstab
fi

# Mount the disk immediately if not already mounted
if ! mountpoint -q /mnt/data; then
  mount /dev/disk/by-id/google-datomic-data-disk /mnt/data
fi
EOT
}

resource "google_project_iam_member" "iap_tunnel_accessor" {
  project = var.project_id
  member = var.iap_access_member
  role = "roles/iap.tunnelResourceAccessor"
}

# Allow SSH in from outside of GCP through IAP

resource "google_compute_firewall" "allow_ssh_ingress_from_iap" {
  project = var.project_id
  name = "${var.name}-ssh-iap-ingress"
  network = google_compute_network.datomic_vpc.id
  direction = "INGRESS"
  allow {
    protocol = "TCP"
    ports = [22]
  }
  source_ranges = ["35.235.240.0/20"]
}

# Allow outbound traffic from the VM

resource "google_compute_firewall" "gcf_server_egress" {
  project = var.project_id
  name = "${var.name}-gcf-egress"
  network = google_compute_network.datomic_vpc.id
  direction = "EGRESS"
  allow {
    protocol = "all"
  }

  destination_ranges = ["0.0.0.0/0"]
}

# Allow connecting to the transactor

resource "google_compute_firewall" "gcf_datomic_ingress" {
  project = var.project_id
  name = "${var.name}-gcf-transactor-ingress"
  network = google_compute_network.datomic_vpc.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports = ["4337", "4338", "4339"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# Allow connecting to Postgres

resource "google_compute_firewall" "gcf_psql_ingress_psql" {
  project = var.project_id
  name = "${var.name}-gcf-psql-ingress"
  network = google_compute_network.datomic_vpc.id
  direction = "INGRESS"
  allow {
    protocol = "tcp"
    ports = ["5432"]
  }

  source_ranges = ["0.0.0.0/0"]
}

# These are required for the machine to reach the internet

resource "google_compute_router" "datomic_router" {
  project = var.project_id
  region = var.region
  network = google_compute_network.datomic_vpc.id
  name = "${var.name}-router"

  bgp {
    asn = 64514
  }
}

module "cloud-nat" {
  source = "terraform-google-modules/cloud-nat/google"
  project_id = var.project_id
  region = var.region
  version = "~> 5.0"
  router = google_compute_router.datomic_router.name
  name = "${var.name}-nat"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Set up postgresql user and password as secrets

resource "random_string" "password" {
  length = 20
  special = false
}

resource "google_secret_manager_secret" "psql_password" {
  project = var.project_id
  secret_id = "${var.name}-postgres-password"

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret" "psql_user" {
  project = var.project_id
  secret_id = "${var.name}-postgres-user"

  replication {
    user_managed {
      replicas {
        location = var.region
      }
    }
  }
}

resource "google_secret_manager_secret_version" "psql_password" {
  secret = google_secret_manager_secret.psql_password.id
  secret_data = random_string.password.result
}

resource "google_secret_manager_secret_version" "psql_user" {
  secret = google_secret_manager_secret.psql_user.id
  secret_data = "${var.name}"
}
