#!/usr/bin/env bats

setup_file() {
    REPO_ROOT="$( cd "$(dirname "$BATS_TEST_FILENAME")/.." >/dev/null 2>&1 && pwd )"
    cd $REPO_ROOT
    
    make
    TMP_DIR=$(mktemp -d)
    export TMP_DIR
    
    curl -sLo "${TMP_DIR}/kubectl" "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x "${TMP_DIR}/kubectl"
    curl -sLo "${TMP_DIR}/kind" https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
    chmod +x "${TMP_DIR}/kind"

    PATH="${TMP_DIR}:${PATH}"
    export PATH
    
    # Create cluster
    cat << 'EOC' | kind create cluster --name kccm --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30000
    hostPort: 30000
    listenAddress: "0.0.0.0"
    protocol: TCP
  - containerPort: 30001
    hostPort: 30001
    listenAddress: "0.0.0.0"
    protocol: TCP
EOC

    kind get kubeconfig --name kccm > "${TMP_DIR}/kubeconfig"
    
    # Simple wait for node to be ready
    echo "Waiting for node to be ready..."
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" wait --for=condition=ready node --all --timeout=5m
    
    # Wait for any system pod to be ready as indication cluster is working
    echo "Waiting for system pods..."
    sleep 30
    
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" label node kccm-control-plane node.kubernetes.io/exclude-from-external-load-balancers- --overwrite
    
    nohup bin/cloud-provider-kind > ${TMP_DIR}/kccm-kind.log 2>&1 &
    CLOUD_PROVIDER_KIND_PID=$!
    sleep 20  # Give more time for cloud provider to start
}

teardown_file() {
    kill -9 ${CLOUD_PROVIDER_KIND_PID} 2>/dev/null || true
    kind delete cluster --name kccm || true

    if [[ -n "${TMP_DIR:-}" ]]; then
        rm -rf "${TMP_DIR}"
    fi
}

@test "ExternalTrafficPolicy Local" {
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" apply -f examples/loadbalancer_etp_local.yaml
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" wait --for=condition=ready pods -l app=MyLocalApp --timeout=2m
    
    POD=$(kubectl --kubeconfig "${TMP_DIR}/kubeconfig" get pod -l app=MyLocalApp -o jsonpath='{.items[0].metadata.name}')
    echo "Pod: $POD"
    
    for i in {1..15}
    do
        HOSTNAME=$(curl -s --connect-timeout 5 http://localhost:30000/hostname || true)
        echo "Attempt $i: Hostname='$HOSTNAME', Expected='$POD'"
        if [ ! -z "$HOSTNAME" ] && [ "$HOSTNAME" = "$POD" ]; then
            echo "✅ SUCCESS on attempt $i"
            break
        fi
        sleep 3
    done
    
    [ "$HOSTNAME" = "$POD" ]
}

@test "ExternalTrafficPolicy Cluster" {
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" apply -f examples/loadbalancer_etp_cluster.yaml
    kubectl --kubeconfig "${TMP_DIR}/kubeconfig" wait --for=condition=ready pods -l app=MyClusterApp --timeout=2m
    
    POD=$(kubectl --kubeconfig "${TMP_DIR}/kubeconfig" get pod -l app=MyClusterApp -o jsonpath='{.items[0].metadata.name}')
    echo "Pod: $POD"
    
    for i in {1..15}
    do
        HOSTNAME=$(curl -s --connect-timeout 5 http://localhost:30001/hostname || true)
        echo "Attempt $i: Hostname='$HOSTNAME', Expected='$POD'"
        if [ ! -z "$HOSTNAME" ] && [ "$HOSTNAME" = "$POD" ]; then
            echo "✅ SUCCESS on attempt $i"
            break
        fi
        sleep 3
    done
    
    [ "$HOSTNAME" = "$POD" ]
}
