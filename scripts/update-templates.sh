#!/bin/bash
set -e

echo "[INFO] Updating Kubernetes versions..."

K8S_API_URL="https://api.github.com/repos/kubernetes/kubernetes/releases?per_page=100"
TMP_VERSIONS="/tmp/k8s-versions.txt"
TMP_YAML="/tmp/k8s-versions.yaml"

curl -s "$K8S_API_URL" | jq -r '.[] | select(.prerelease == false) | .tag_name' \
  | grep -E '^v1\.[0-9]+\.[0-9]+$' \
  | grep -v '\-alpha' | grep -v '\-beta' | grep -v '\-rc' \
  | sort -Vr > "$TMP_VERSIONS.all"

awk -F. '
  {
    key = $1 "." $2
    if (!seen[key]++) {
      print "- " $0
    }
  }
' "$TMP_VERSIONS.all" | head -n 4 > "$TMP_YAML"

DEFAULT_K8S=$(sed -n 2p "$TMP_YAML" | cut -d' ' -f2)

yq e -i '
  (.[] | select(.variable == "k8sVersion")).options = load("'"$TMP_YAML"'")
' shared/parameters.yaml

yq e -i '
  (.[] | select(.variable == "k8sVersion")).defaultValue = "'"$DEFAULT_K8S"'"
' shared/parameters.yaml

echo "[INFO] Updating vCluster chart versions and parameters..."

REPO_URL="https://charts.loft.sh"
CHART_NAME="vcluster"

LATEST_VCLUSTER=$(curl -s "$REPO_URL/index.yaml" \
  | yq e ".entries.$CHART_NAME[].version" - \
  | grep -v '\-alpha' | grep -v '\-beta' | grep -v '\-rc' \
  | sort -Vr \
  | head -n1)

sleep_param_file="/tmp/sleepAfter.yaml"
k8s_param_file="/tmp/k8sVersion.yaml"

yq e '.[] | select(.variable == "sleepAfter")' shared/parameters.yaml > "$sleep_param_file"
yq e '.[] | select(.variable == "k8sVersion")' shared/parameters.yaml > "$k8s_param_file"

# The find command goes here, at the end of the while loop,
# using process substitution to feed its output to the loop.
while IFS= read -r file; do

  echo "Updating $file"

  kind=$(yq e 'select(.kind == "VirtualClusterTemplate") | .kind' "$file" 2>/dev/null || echo "")

  if [[ "$kind" != "VirtualClusterTemplate" ]]; then
    echo "  ↳ Skipping non-VirtualClusterTemplate file"
    continue
  fi

  has_versions=$(yq e 'has("spec") and (.spec.versions | type == "!!seq")' "$file")
  if [[ "$has_versions" == "true" ]]; then
    echo "[INFO] Updating versioned templates..."

    current_chart=$(yq e '.spec.versions[] | select(.version == "1.0.0") | .template.helmRelease.chart.version' "$file" | head -n1)
    has_parameters=$(yq e '.spec.versions[] | select(.version == "1.0.0") | has("parameters")' "$file")
    if [[ "$current_chart" != "$LATEST_VCLUSTER" || "$has_parameters" == "true" ]]; then
      # Extract the .values key into a clean YAML block
      yq eval '.spec.versions[] | select(.version == "1.0.0") | .template.helmRelease.values' "$file" > /tmp/decoded-values.yaml

      if [[ "$current_chart" != "$LATEST_VCLUSTER" ]]; then
        echo "  ↳ Updating versioned chart from $current_chart to $LATEST_VCLUSTER"
        yq e -i '(.spec.versions[] | select(.version == "1.0.0")).template.helmRelease.chart.version = "'"$LATEST_VCLUSTER"'"' "$file"
      fi
      
      if [[ "$has_parameters" == "true" ]]; then
        echo "  ↳ Updating parameters"
        yq e -i '
          (.spec.versions[] | select(.version == "1.0.0")).parameters |= 
            (. // [] | map(select(.variable != "sleepAfter" and .variable != "k8sVersion")))
        ' "$file"

        yq e -i '
          (.spec.versions[] | select(.version == "1.0.0")).parameters += 
            [load("'"$sleep_param_file"'"), load("'"$k8s_param_file"'")]
        ' "$file"
      else
        echo "  ↳ Skipping parameter update"
      fi

      yq eval -i '
        (.spec.versions[] | select(.version == "1.0.0")).template.helmRelease.values = load("/tmp/decoded-values.yaml")
      ' "$file"

      perl -pi -e 's/values:(?! ?\|)/values: |/' "$file"
    fi

  else
    chart_version=$(yq e '.spec.template.helmRelease.chart.version // ""' "$file")
    # Check if .spec.parameters exists before mutating
    has_parameters=$(yq e 'has("spec") and .spec | has("parameters")' "$file")
    if [[  ( -n "$chart_version" && "$chart_version" != "$LATEST_VCLUSTER" ) || "$has_parameters" == "true" ]]; then
      # Extract the .values key into a clean YAML block
      yq eval '.spec.template.helmRelease.values' "$file" > /tmp/decoded-values.yaml
      if [[ -n "$chart_version" && "$chart_version" != "$LATEST_VCLUSTER" ]]; then
        echo "  ↳ Updating chart version from $chart_version to $LATEST_VCLUSTER"
        yq e -i '.spec.template.helmRelease.chart.version = "'"$LATEST_VCLUSTER"'"' "$file"
      fi
      
      if [[ "$has_parameters" == "true" ]]; then
        echo "  ↳ Updating parameters"
        yq e -i '
          .spec.parameters = (.spec.parameters // [] | map(select(.variable != "sleepAfter" and .variable != "k8sVersion")))
        ' "$file"

        yq e -i '
          .spec.parameters += [load("'"$sleep_param_file"'"), load("'"$k8s_param_file"'")]
        ' "$file"
      else
        echo "  ↳ Skipping parameter update (no .spec.parameters block found)"
      fi

      yq eval -i '
        .spec.template.helmRelease.values = load("/tmp/decoded-values.yaml")
      ' "$file"

      perl -pi -e 's/values:(?! ?\|)/values: |/' "$file"
    fi
  fi
done < <(find vcluster-gitops vcluster-use-cases -type f -name "*.yaml") 
