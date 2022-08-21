provider "google" {
  version = "~> 4.32.0"
  project = "${var.gcp_project}"
  region  = "${var.gcp_region}"
}

provider "kubernetes" {
  version = "~> 2.12.1"

  host     = "https://${google_container_cluster.gke_cluster.endpoint}"
  username = "${var.master_username}"
  password = "${var.master_password}"

  client_certificate     = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.client_certificate)}"
  client_key             = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.client_key)}"
  cluster_ca_certificate = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.cluster_ca_certificate)}"
}

module "google_container_cluster" "gke_cluster" {
  source             = "hashicorp/google"
  name               = "${var.cluster_name}"
  region             = "${var.gcp_region}"
  min_master_version = "${var.master_version}"

  master_auth {
    username = "${var.master_username}"
    password = "${var.master_password}"
  }

  lifecycle {
    ignore_changes = ["node_pool"]
  }

  node_pool {
    name = "default-pool"
  }
}

resource "google_container_node_pool" "gke_node_pool" {
  name       = "${var.cluster_name}-pool"
  region     = "${var.gcp_region}"
  cluster    = "${google_container_cluster.gke_cluster.name}"
  node_count = "${var.min_node_count}"

  autoscaling {
    min_node_count = "${var.min_node_count}"
    max_node_count = "${var.max_node_count}"
  }

  node_config {
    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
    ]
  }
}

resource "null_resource" "install_istio" {
  triggers {
    cluster_ep = "${google_container_cluster.gke_cluster.endpoint}"
  }

  provisioner "local-exec" {
    command = <<EOT
      echo "$${CA_CERTIFICATE}" > ca.crt
      kubectl config --kubeconfig=ci set-cluster k8s --server=$${K8S_SERVER} --certificate-authority=ca.crt
      kubectl config --kubeconfig=ci set-credentials admin --username=$${K8S_USERNAME} --password=$${K8S_PASSWORD}
      kubectl config --kubeconfig=ci set-context k8s-ci --cluster=k8s --namespace=default --user=admin
      kubectl config --kubeconfig=ci use-context k8s-ci
      export KUBECONFIG=ci

      kubectl create ns production
      kubectl create ns stage
      helm init --upgrade 
      helm repo add kubernetes-istio-module $${HELM_REPO}
      helm repo update

      kubectl create ns istio-system 
      helm install --name istio --namespace istio-system --set grafana.enabled=true istio.io/istio
      kubectl label namespace default istio-injection=enabled

      kubectl create ns production
      kubectl create ns stage
      helm init --upgrade 
      helm repo add https://github.com/olaoluwatx/Walt-code
      helm install walt-code rlt-test -n production
      helm install walt-code rlt-test -n stage 

    EOT

    environment {
      CA_CERTIFICATE = "${base64decode(google_container_cluster.gke_cluster.master_auth.0.cluster_ca_certificate)}"
      K8S_SERVER     = "https://${google_container_cluster.gke_cluster.endpoint}"
      K8S_USERNAME   = "${var.master_username}"
      K8S_PASSWORD   = "${var.master_password}"
      HELM_REPO      = "${var.helm_repository}"
    
    }
  }

  depends_on = ["google_container_node_pool.gke_node_pool"]
}
