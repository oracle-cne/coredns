#! /bin/bash

set -eE
set -x

ls -l /dev/stdin
ls -l /proc/self/fd/0

stat /dev/stdin
stat /proc/self/fd/0

stat -L /dev/stdin
stat -L /proc/self/fd/0

if ! which ocne; then
	if [ -z "$COREDNS_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y ocne
	else
		echo "The ocne cli is required"
		exit 1
	fi
fi

if ! which podman; then
	if [ -z "$COREDNS_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y podman
	else
		echo "podman is required"
		exit 1
	fi
fi

if ! which kubectl; then
	if [ -z "$COREDNS_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y kubectl
	else
		echo "kubectl is required"
		exit 1
	fi
fi

if ! which git; then
	if [ -z "$COREDNS_SKIP_INSTALL_DEPS" ]; then
		sudo dnf install -y git
	else
		echo "git is required"
		exit 1
	fi
fi

git clone https://github.com/oracle-cne/tests ocne-tests

if ! which virsh; then
	if [ -z "$COREDNS_SKIP_INSTALL_DEPS" ]; then
		if [ -f /etc/os-release ]; then
			os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
			os_version_id=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
			os_major_version=${os_version_id%%.*}

			if [ "$os_id" = "ol" ] && [ "$os_major_version" = "8" ]; then
				dnf install -y oracle-ocne-release-el8 oraclelinux-developer-release-el8 oracle-epel-release-el8
				dnf config-manager --enable ol8_kvm_appstream ol8_UEKR7 ol8_ocne ol8_developer_EPEL ol8_olcne19 ol8_codeready_builder

				dnf module reset virt:ol
				dnf module install -y virt:kvm_utils3/common

				if [ -z "$(rpm -qa podman)" ]; then
					dnf install -y podman
				fi


				# Fix up an issue with libvirt and XATTR in containers
				sed -i 's/#remember_owner = 1/remember_owner = 0/g' /etc/libvirt/qemu.conf
				sed -i 's/#namespaces = .*/namespaces = []/g' /etc/libvirt/qemu.conf

				if [ ! -e /dev/kvm ] && [ -n "$KVM_MINOR" ]; then
					mknod /dev/kvm c 10 $KVM_MINOR
				fi

				systemctl enable --now libvirtd.service

			fi
		fi
	fi
fi

export COREDNS_CLUSTER_NAME=coredns-test
export IMG_NAME="container-registry.oracle.com/olcne/coredns"
export TAG="v1.14.2"
export NGINX_IMG_NAME="container-registry.oracle.com/olcne/nginx"
export COREDNS_NAMESPACE="${COREDNS_NAMESPACE:-kube-system}"
control_plane_node_count=3
worker_node_count=3
expected_cluster_node_count=$((control_plane_node_count + worker_node_count))
cluster_node_wait_timeout_seconds="${CLUSTER_NODE_WAIT_TIMEOUT_SECONDS:-600}"
cluster_node_wait_poll_seconds="${CLUSTER_NODE_WAIT_POLL_SECONDS:-10}"
coredns_selector=""
coredns_deployment=""
delete_ocne_cluster=false
test_started=false

wait_for_cluster_nodes() {
	local expected_node_count="$1"
	local timeout_seconds="$2"
	local poll_seconds="$3"
	local deadline=$((SECONDS + timeout_seconds))
	local current_node_count=0
	local current_ready_node_count=0

	echo "Waiting for ${expected_node_count} cluster nodes to register"

	while [ "$SECONDS" -lt "$deadline" ]; do
		if ! kubectl get nodes >/dev/null 2>&1; then
			echo "Cluster API is not ready yet; retrying node discovery in ${poll_seconds}s"
			sleep "$poll_seconds"
			continue
		fi

		current_node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
		current_ready_node_count=$(
			kubectl get nodes --no-headers 2>/dev/null |
				awk '$2 ~ /(^|,)Ready(,|$)/ { count++ } END { print count + 0 }'
		)

		echo "Discovered ${current_node_count}/${expected_node_count} nodes with ${current_ready_node_count}/${expected_node_count} Ready"

		if [ "$current_node_count" -eq "$expected_node_count" ]; then
			echo "All ${expected_node_count} nodes are registered; waiting for Ready condition"
			if kubectl wait --for=condition=Ready nodes --all --timeout="${poll_seconds}s"; then
				final_ready_node_count=$(
					kubectl get nodes --no-headers 2>/dev/null |
						awk '$2 ~ /(^|,)Ready(,|$)/ { count++ } END { print count + 0 }'
				)

				if [ "$final_ready_node_count" -eq "$expected_node_count" ]; then
					echo "All ${expected_node_count} cluster nodes are online and Ready"
					return 0
				fi
			fi
		fi

		sleep "$poll_seconds"
	done

	echo "Timed out after ${timeout_seconds}s waiting for ${expected_node_count} cluster nodes to come online"
	kubectl get nodes -o wide || true
	return 1
}

discover_coredns_deployment() {
	local deployment_info=""

	deployment_info=$(
		kubectl get deployment -A -o go-template='{{range .items}}{{ $ns := .metadata.namespace }}{{ $name := .metadata.name }}{{range .spec.template.spec.containers}}{{printf "%s\t%s\t%s\n" $ns $name .image}}{{end}}{{end}}' |
			awk -v repo="$IMG_NAME" '
				index($3, repo ":") == 1 || index($3, repo "@") == 1 { print $1 "\t" $2; exit }
			'
	)

	if [ -z "$deployment_info" ]; then
		deployment_info=$(
			kubectl get deployment -A -o go-template='{{range .items}}{{printf "%s\t%s\n" .metadata.namespace .metadata.name}}{{end}}' |
				awk '
					$2 == "coredns" || $2 == "kube-dns" || $2 ~ /(^|-)coredns(-|$)/ || $2 ~ /(^|-)kube-dns(-|$)/ {
						print $1 "\t" $2
						exit
					}
				'
		)
	fi

	if [ -z "$deployment_info" ]; then
		echo "Unable to find a CoreDNS deployment in the cluster"
		kubectl get deployment -A -o wide || true
		exit 1
	fi

	COREDNS_NAMESPACE=$(printf '%s\n' "$deployment_info" | awk 'NR == 1 { print $1 }')
	coredns_deployment=$(printf '%s\n' "$deployment_info" | awk 'NR == 1 { print $2 }')

	if [ -z "$COREDNS_NAMESPACE" ] || [ -z "$coredns_deployment" ]; then
		echo "Unable to parse the CoreDNS deployment information"
		printf '%s\n' "$deployment_info"
		exit 1
	fi

	coredns_selector=$(
		kubectl get deployment "$coredns_deployment" -n "$COREDNS_NAMESPACE" \
			-o go-template='{{range $key, $value := .spec.selector.matchLabels}}{{printf "%s=%s\n" $key $value}}{{end}}' |
			awk '
				BEGIN { separator = "" }
				NF {
					printf "%s%s", separator, $0
					separator = ","
				}
				END {
					printf "\n"
				}
			'
	)

	if [ -z "$coredns_selector" ]; then
		echo "Unable to determine the CoreDNS pod selector from deployment ${coredns_deployment} in namespace ${COREDNS_NAMESPACE}"
		kubectl get deployment "$coredns_deployment" -n "$COREDNS_NAMESPACE" -o yaml || true
		exit 1
	fi

	echo "Using CoreDNS deployment ${coredns_deployment} in namespace ${COREDNS_NAMESPACE} with selector ${coredns_selector}"
}

if [ -z "${KUBECONFIG:-}" ]; then
	delete_ocne_cluster=true
	ocne cluster start --auto-start-ui=false -C "$COREDNS_CLUSTER_NAME" --control-plane-nodes "$control_plane_node_count" --worker-nodes "$worker_node_count"
	export KUBECONFIG
	KUBECONFIG=$(ocne cluster show -C "$COREDNS_CLUSTER_NAME")
	wait_for_cluster_nodes "$expected_cluster_node_count" "$cluster_node_wait_timeout_seconds" "$cluster_node_wait_poll_seconds"
fi

cluster_nodes=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [ -z "$cluster_nodes" ]; then
	echo "Unable to determine the cluster nodes from the current KUBECONFIG"
	exit 1
fi

nginx_tag=""
for cluster_node in $cluster_nodes; do
	echo "Inspecting ${NGINX_IMG_NAME} on node ${cluster_node}"
	node_nginx_tags=$(
		ocne cluster console --direct --node "$cluster_node" -- podman images --format '{{.Repository}} {{.Tag}}' |
			awk -v repo="$NGINX_IMG_NAME" '$1 == repo && $2 != "<none>" { print $2 }' |
			sort -u
	)

	if [ -z "$node_nginx_tags" ]; then
		echo "Node ${cluster_node} does not have ${NGINX_IMG_NAME}"
		exit 1
	fi

	if [ "$(printf '%s\n' "$node_nginx_tags" | awk 'NF { count++ } END { print count + 0 }')" -ne 1 ]; then
		echo "Node ${cluster_node} has multiple tags for ${NGINX_IMG_NAME}: ${node_nginx_tags}"
		exit 1
	fi

	node_nginx_tag=$(printf '%s\n' "$node_nginx_tags")
	echo "Node ${cluster_node} uses nginx image tag ${node_nginx_tag}"

	if [ -z "$nginx_tag" ]; then
		nginx_tag="$node_nginx_tag"
	elif [ "$nginx_tag" != "$node_nginx_tag" ]; then
		echo "Node ${cluster_node} has nginx image tag ${node_nginx_tag}, expected ${nginx_tag}"
		exit 1
	fi

	podman save "${IMG_NAME}:${TAG}" | ocne cluster console --direct --node "$cluster_node" -- podman load
	echo -n "" | ocne cluster console --direct --node "$cluster_node" -- podman tag "${IMG_NAME}:${TAG}" "${IMG_NAME}:current"
done

if [ -z "$nginx_tag" ]; then
	echo "Unable to determine a shared nginx image tag from the cluster nodes"
	exit 1
fi

# ocne-tests prepends its own registry/repository prefix, so only pass nginx:<tag>.
NGINX_IMAGE="nginx:${nginx_tag}"
echo "Using downstream nginx image override ${NGINX_IMAGE} for ocne-tests"

ocne_basic_test_script=""
for candidate in ocne-tests/tools/basic_k8s_tests.sh ocne-tests/tools/basic_k8s_test.sh; do
	if [ -f "$candidate" ]; then
		ocne_basic_test_script="$candidate"
		break
	fi
done

if [ -z "$ocne_basic_test_script" ]; then
	echo "Unable to find ocne-tests basic Kubernetes test script"
	exit 1
fi

if grep -q '^NGINX_IMAGE=' "$ocne_basic_test_script"; then
	sed -i "s|^NGINX_IMAGE=.*|NGINX_IMAGE=\"${NGINX_IMAGE}\"|" "$ocne_basic_test_script"
else
	sed -i "1a NGINX_IMAGE=\"${NGINX_IMAGE}\"" "$ocne_basic_test_script"
fi

cat "${ocne_basic_test_script}"

echo "Updated ${ocne_basic_test_script} to use ${NGINX_IMAGE}"

report_test_failure() {
	if [ "$test_started" != true ]; then
		return
	fi

	trap - ERR
	set +e

	echo "Test failed; collecting cluster diagnostics"
	kubectl get nodes -o wide || true

	if [ -n "$coredns_selector" ]; then
		kubectl get pods -n "$COREDNS_NAMESPACE" -l "$coredns_selector" -o wide || true
		kubectl describe pods -n "$COREDNS_NAMESPACE" -l "$coredns_selector" || true
	fi

	if [ -n "$coredns_deployment" ]; then
		kubectl get deployment "$coredns_deployment" -n "$COREDNS_NAMESPACE" -o wide || true
		kubectl describe deployment "$coredns_deployment" -n "$COREDNS_NAMESPACE" || true
	fi

	exit 1
}

trap report_test_failure ERR

discover_coredns_deployment

test_started=true
expected_coredns_pod_count=$(kubectl get pods -n "$COREDNS_NAMESPACE" -l "$coredns_selector" --no-headers 2>/dev/null | wc -l)

if [ "$expected_coredns_pod_count" -eq 0 ]; then
	echo "No CoreDNS pods found in ${COREDNS_NAMESPACE} with selector ${coredns_selector}"
	exit 1
fi

kubectl delete pod -n "$COREDNS_NAMESPACE" -l "$coredns_selector"

for _ in $(seq 1 24); do
	ready_coredns_pods=$(
		kubectl get pods -n "$COREDNS_NAMESPACE" -l "$coredns_selector" \
			-o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' |
			awk '$2 == "" { print $1 }'
	)

	ready_coredns_pod_count=$(printf '%s\n' "$ready_coredns_pods" | awk 'NF { count++ } END { print count + 0 }')

	if [ "$ready_coredns_pod_count" -eq "$expected_coredns_pod_count" ]; then
		break
	fi

	sleep 5
done

if [ "$ready_coredns_pod_count" -ne "$expected_coredns_pod_count" ]; then
	echo "Timed out waiting for all CoreDNS pods to be recreated in ${COREDNS_NAMESPACE}"
	exit 1
fi

kubectl wait --namespace "$COREDNS_NAMESPACE" --for=jsonpath='{.status.phase}'=Running pod -l "$coredns_selector" --timeout=120s
kubectl wait --namespace "$COREDNS_NAMESPACE" --for=condition=Ready pod -l "$coredns_selector" --timeout=120s

cleanup() {
	status=$?
	trap - EXIT

	if [ "$delete_ocne_cluster" = true ]; then
		ocne cluster delete -C "${COREDNS_CLUSTER_NAME}" || status=$?
	fi

	exit "$status"
}

trap cleanup EXIT

sh "$ocne_basic_test_script"

test_started=false
