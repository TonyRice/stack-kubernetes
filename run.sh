#!/usr/bin/env bash

check_kubectl() {
  if ! hash kubectl; then
    echo "ERROR: kubectl not found"
    echo "https://kubernetes.io/docs/tasks/tools/install-kubectl/"
    exit 1
  fi
  echo "Current kubectl context: $(kubectl config current-context)"
  read -p "Continue (y/n)? " CONT
  if [ "$CONT" != "y" ]; then
    echo "EXITING - NO CHANGES MADE"
    exit
  fi
}

check_helm() {
  if ! hash helm; then
    echo "ERROR: helm not found"
    echo "Please install the Helm client only from here https://docs.helm.sh/using_helm/#from-script"
    exit 1
  fi
}

check_skaffold() {
  if ! hash skaffold; then
    echo "ERROR: skaffold not found"
    echo "https://github.com/GoogleCloudPlatform/skaffold#installation"
    exit 1
  fi
}

istio_install() {
  check_kubectl
  ISTIO_VERSION="0.7.1"
  if [ ! -d "istio-$ISTIO_VERSION" ]; then
    curl -L https://git.io/getLatestIstio | ISTIO_VERSION=$ISTIO_VERSION sh -
  fi
  pushd istio-$ISTIO_VERSION > /dev/null || exit 1

  echo "Installing Istio..."
  # install core istio
  kubectl apply -f install/kubernetes/istio-auth.yaml > /dev/null

  # create signed cert for sidecar injection webhook
  ./install/kubernetes/webhook-create-signed-cert.sh --service istio-sidecar-injector --namespace istio-system --secret sidecar-injector-certs > /dev/null 2>&1

  # install sidecar injection configmap
  kubectl apply -f install/kubernetes/istio-sidecar-injector-configmap-release.yaml > /dev/null

  # set caBundle that is used in the webhook
  ./install/kubernetes/webhook-patch-ca-bundle.sh < install/kubernetes/istio-sidecar-injector.yaml > install/kubernetes/istio-sidecar-injector-with-ca-bundle.yaml

  # install sidecar injector webhook
  kubectl apply -f install/kubernetes/istio-sidecar-injector-with-ca-bundle.yaml > /dev/null

  # prometheus
  kubectl apply -f install/kubernetes/addons/prometheus.yaml > /dev/null

  # grafana
  kubectl apply -f install/kubernetes/addons/grafana.yaml > /dev/null

  # zipkin
  kubectl apply -f install/kubernetes/addons/zipkin.yaml > /dev/null

  # servicegraph
  kubectl apply -f install/kubernetes/addons/servicegraph.yaml > /dev/null

  popd > /dev/null
  echo "Waiting for Istio to start..."
  while true; do
    NOT_RUNNING_COUNT=$(kubectl -n istio-system get pod -o=custom-columns=:.status.phase | grep -v "^$" | grep -vc "Running")
    if [ "$NOT_RUNNING_COUNT" -eq 0 ]; then
      break
    else
      sleep 3
    fi
  done

  echo "Istio is ready! Port forwarding commands:"
  echo "Grafana: $ kubectl -n istio-system port-forward $(kubectl -n istio-system get pod -l app=grafana -o jsonpath='{.items[0].metadata.name}') 3000:3000"
  echo "Prometheus: $ kubectl -n istio-system port-forward $(kubectl -n istio-system get pod -l app=prometheus -o jsonpath='{.items[0].metadata.name}') 9090:9090"
  echo "Zipkin: $ kubectl -n istio-system port-forward $(kubectl -n istio-system get pod -l app=zipkin -o jsonpath='{.items[0].metadata.name}') 9411:9411"
  echo "Service Graph: $ kubectl -n istio-system port-forward $(kubectl -n istio-system get pod -l app=servicegraph -o jsonpath='{.items[0].metadata.name}') 8088:8088"
}

asyncy_install_secrets() {
  read -p "Sentry DSN: " SENTRY_DSN
  read -p "PostgreSQL Host: " PG_HOST
  read -p "PostgreSQL DB Name: " PG_DB_NAME
  read -p "PostgreSQL DB Username: " PG_USERNAME
  read -p "PostgreSQL DB Password: " -s PG_PASSWORD
  echo
  read -p "PostgreSQL DB Username (for asyncy_authenticator): " PG_AA_USERNAME
  read -p "PostgreSQL DB Password (for asyncy_authenticator): " -s PG_AA_PASSWORD
  echo
  read -p "MySQL/PostgreSQL DB URI for Grafana (mysql://... or postgres://...): " -s PG_CONN_GRAFANA_URI
  echo
  CONNECTION_STRING="options=--search_path=app_public,app_hidden,app_private,public dbname=$PG_DB_NAME host=$PG_HOST user=$PG_USERNAME password=$PG_PASSWORD"
  CONNECTION_STRING_URI="postgres://$PG_USERNAME:$PG_PASSWORD@$PG_HOST/$PG_DB_NAME"
  CONNECTION_STRING_URI_JDBC="jdbc:postgresql://$PG_HOST/$PG_DB_NAME?user=$PG_USERNAME&password=$PG_PASSWORD&currentSchema=app_public,app_private,app_hidden,app_runtime,public"
  CONNECTION_STRING_URI_AA="postgres://$PG_AA_USERNAME:$PG_AA_PASSWORD@$PG_HOST/$PG_DB_NAME"
  PG_HOST= PG_DB_NAME= PG_USERNAME= PG_PASSWORD= PG_AA_PASSWORD= PG_AA_USERNAME=

  kubectl create secret generic database-url --from-literal=authenticator-uri="$CONNECTION_STRING_URI_AA" --from-literal=root-dsn="$CONNECTION_STRING" --from-literal=root-uri="$CONNECTION_STRING_URI" --from-literal=grafana-uri="$PG_CONN_GRAFANA_URI" --from-literal=jdbc-root-uri="$CONNECTION_STRING_URI_JDBC"
  CONNECTION_STRING= CONNECTION_STRING_URI= CONNECTION_STRING_URI_AA= PG_CONN_GRAFANA_URI= CONNECTION_STRING_URI_JDBC=

  kubectl create secret generic sentry --from-literal=sentry_dsn=$SENTRY_DSN
  SENTRY_DSN=

  read -p "Full path to privkey.pem (for *.storyscript.io): " PRIV_KEY
  read -p "Full path to fullchain.pem (for *.storyscript.io): " FULLCHAIN
  kubectl create secret tls storyscript.io --key $PRIV_KEY --cert $FULLCHAIN

  read -p "Full path to privkey.pem (for *.storyscriptapp.com): " PRIV_KEY
  read -p "Full path to fullchain.pem (for *.storyscriptapp.com): " FULLCHAIN
  kubectl create secret tls storyscriptapp.com --key $PRIV_KEY --cert $FULLCHAIN

  read -p "GitHub OAuth Token (for the Hub): " GH_TOKEN
  read -p "GitHub OAuth Client ID (for hub-api): " GH_CLIENT_ID
  read -p "GitHub OAuth Client Secret (for hub-api): " GH_CLIENT_SECRET
  kubectl create secret generic github --from-literal=oauth_token="$GH_TOKEN" --from-literal=client_id="$GH_CLIENT_ID" --from-literal=client_secret="$GH_CLIENT_SECRET"

  read -p "JWT cookie secret key (for hub-api): " JWT_SECRET
  kubectl create secret generic hub --from-literal=jwt_secret="$JWT_SECRET"
}

asyncy_install() {
  check_kubectl
  check_skaffold
  check_helm

  echo "Installing Helm and Nginx"
  # create RBAC role and cluster binding for Tiller - the Helm server
  kubectl create serviceaccount --namespace kube-system tiller
  kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
  kubectl create -f kubernetes-pre-init/role_bindings/tiller.yaml
  helm init --service-account tiller --upgrade
  while ! kubectl get pod -n kube-system | grep tiller-deploy | grep Running &> /dev/null; do
    echo "Waiting for the tiller-deploy pod to be ready..."
    sleep 1
  done
  helm install --name nginx-ingress stable/nginx-ingress --set rbac.create=true

  echo "Installing Asyncy..."
  # creating the asyncy namespace
  kubectl create namespace asyncy-system

  kubectl create -f kubernetes-pre-init/cluster_roles/filebeat.yaml
  kubectl create -f kubernetes-pre-init/service_accounts/filebeat.yaml
  kubectl create -f kubernetes-pre-init/role_bindings/filebeat.yaml

  kubectl create -f kubernetes-pre-init/service_accounts/engine.yaml
  kubectl create -f kubernetes-pre-init/role_bindings/engine.yaml
  kubectl create -f kubernetes-pre-init/secrets/engine.yaml

  kubectl create -f kubernetes-pre-init/service_accounts/synapse.yaml
  kubectl create -f kubernetes-pre-init/role_bindings/synapse.yaml
  kubectl create -f kubernetes-pre-init/secrets/synapse.yaml

  # create the secrets required
  asyncy_install_secrets


  # enabling istio sidecar injection
  kubectl label namespace asyncy-system istio-injection=enabled > /dev/null

  # deploying components
  skaffold run -f skaffold-deploy.yaml

  echo "Asyncy is ready!"
}

asyncy_dev() {
  check_skaffold
  echo "Running Skaffold dev and watching for Asyncy platform changes..."
  skaffold dev -f skaffold.yaml
}

asyncy_update() {
  check_kubectl
  check_skaffold
  echo "Updating Asyncy..."
  skaffold run -f skaffold-deploy.yaml
}
    

usage() {
  echo "Usage: $0 <arg>"
  echo
  echo "Options:"
  echo "istio-install"
  echo "asyncy-install"
  echo "asyncy-install-secrets"
  echo "asyncy-dev"
  echo "asyncy-update"
}

main() {
  RUN="$1"
  if [ -z "$RUN" ]; then
    usage
    exit 1
  else
    case "$RUN" in
      istio-install)
        istio_install
        ;;
      asyncy-install)
        asyncy_install
        ;;
      asyncy-install-secrets)
        asyncy_install_secrets
        ;;
      asyncy-dev)
        asyncy_dev
        ;;
      asyncy-update)
        asyncy_update
        ;;
      *)
        usage
        exit 1
    esac
  fi
}

main "$1"
