variable "project_id" {
  type = string
  description = "The project id"
}

variable "region" {
  type = string
  description = "The GCP region"
  default = "europe-north1"
}

variable "zone" {
  type = string
  description = "The GCP availability zone, a/b/c"
  default = "a"
}

variable "vm_machine_type" {
  type = string
  description = "The GCP instance type for the Datomic transactor VM"
  default = "e2-standard-2"
}

variable "ssd_size" {
  type = number
  description = "The number of gigabytes to allocate on the external disk"
  default = 10
}

variable "iap_access_member" {
  type = string
  description = "Which member should have access to the Datomic VPC IAP accessor"
}

variable "name" {
  type = string
  description = "Name of database, used as prefix for uniquely named resources"
  default = "datomic"
}
