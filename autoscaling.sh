#!/bin/bash -l

get_api_key () {
  local APIKEY="DEFAULT-API-KEY"
  local o
  o=$(curl -s http://169.254.169.254/latest/user-data | jq -r '.APIKEY' 2> /dev/null)

  if [ $? -eq 0 ]; then
    echo "$o"
  else
    echo "$APIKEY"
  fi
}

get_service_id () {
  local SERVICEID="DEFAULT-SERVICE-ID"
  local o
  o=$(curl -s http://169.254.169.254/latest/user-data | jq -r '.SERVICEID' 2> /dev/null)
  if [ $? -eq 0 ]; then
    echo "$o"
  else
    echo "$SERVICEID"
  fi
}

get_private_ip () {
  curl -s http://169.254.169.254/latest/meta-data/local-ipv4
}

get_public_ip () {
  curl -s http://169.254.169.254/latest/meta-data/public-ipv4
}

find_active_version () {
  curl -s -X GET -H "X-Fastly-Key: $1" https://api.fastly.com/service/$2/version | jq -c '.[] | select(.active == true) | .number'
}

find_backend () {
  local found="1"

  local api="$1"
  local serviceid="$2"
  local version="$3"
  local private_ip="$4"
  local public_ip="$5"

  local current_backends=`curl -s -X GET -H "X-Fastly-Key: $api" "https://api.fastly.com/service/$serviceid/version/$version/backend" | jq -r ".[] | select((.ipv4 == \"$public_ip\") and (.name == \"$private_ip\"))"`

  if [ "$(echo "$current_backends" | jq -r '.ipv4')" = "$public_ip" ]; then
    echo "public ip match"
    if [ "$(echo "$current_backends" | jq -r '.name')" = "$private_ip" ]; then
      echo "private ip match"
      found="0"
    else
      found="1"
    fi
  fi

  return $found
}

remove_backend () {
  local api="$1"
  local serviceid="$2"
  local version="$3"
  local name="$4"
  curl -s -X DELETE -H "X-Fastly-Key: $api" "https://api.fastly.com/service/$serviceid/version/$version/backend/$name"
}

fetch_backend () {
  local api="$1"
  local serviceid="$2"
  local version="$3"
  local o=`curl -s -H "X-Fastly-Key: $api" "https://api.fastly.com/service/$serviceid/version/$version/backend" | jq -r '.[] | select (.healthcheck == "Check Image Server")'`
  echo -e "$o"
}

is_healthy() {
  echo "Dig result"
  dig +tcp @127.0.0.1 -p 8600 image.service.dc1.consul. A  | grep 'image.service.dc1.consul. 0'
  echo "===="

  dig +tcp @127.0.0.1 -p 8600 image.service.dc1.consul. A |  grep -q "$1"
  return "$?"
}

cleanup_dead_backend () {
  local api="$1"
  local serviceid="$2"
  local version="$3"

  for b in $(fetch_backend "$api" "$serviceid" "$version" | jq -r '.name'); do
    if [ echo "$b" | grep "image" ]; then
      echo "Backend with image in hostname won't be removed automatically"
      continue
    fi
    echo "Review backend $b"
    if is_healthy "$b" ; then
      echo "-> Healthy"
    else
      echo "-> UnHealthy. Remove"
      remove_backend "$api" "$serviceid" "$version" "$b"
    fi
    echo -e "\n"
  done
}

need_update() {
  local result=1
  local api="$1"
  local serviceid="$2"

  local version=$(find_active_version "$api" "$serviceid")
  echo "Current version: $version"

  if is_healthy "$(get_private_ip)"; then
   if ! find_backend "$api" "$serviceid" "$version" $(get_private_ip) $(get_public_ip); then
     echo "need update because of I'm healthy but not on server pool"
     return 0
   fi
  fi

  for b in $(fetch_backend "$api" "$serviceid" "$version" | jq -r '.name'); do
    if ! is_healthy "$b" ; then
      echo "need update because of an unhealthy backend $b"
      result="0"
      break
    fi
  done

  return "$result"
}

add_backend () {
  local api="$1"
  local serviceid="$2"
  local current_version="$3"
  local name="$4"
  local ip="$5"

  # CLone current version
  local new_version=`curl -s -X PUT -H "X-Fastly-Key: $api" "https://api.fastly.com/service/$serviceid/version/$current_version/clone" | jq -r '.number'`

  cleanup_dead_backend "$api" "$serviceid" "$new_version"

  # Add backend to it
  local body="address=$ip&ipv4=$ip&name=$name&port=8899&auto_loadbalance=1&healthcheck=Check Image Server&shield=jfk-ny-us&max_conn=1500&first_byte_timeout=20000&error_threshold=10&connect_timeout=15000&between_bytes_timeout=20000"
  local backend_result=`curl -s -X POST -H "X-Fastly-Key: $api" --data "$body" "https://api.fastly.com/service/$serviceid/version/$new_version/backend"` # | jq -r '.ipv4'`
  if echo "$backend_result" | grep -q "Duplicate backend"; then
    # Remove it
    remove_backend "$api" "$serviceid" "$new_version" "$name"
    backend_result=`curl -s -X POST -H "X-Fastly-Key: $api" --data "$body" "https://api.fastly.com/service/$serviceid/version/$new_version/backend"`
  fi
  echo "be $backend_result"

  backend_result=`echo "$backend_result" | jq -r '.ipv4'`
  if [ "$backend_result" != "$ip" ]; then
    return 1
  fi

  # Validate it
  local validate=`curl -s -X GET -H "X-Fastly-Key: $api" "https://api.fastly.com/service/$serviceid/version/$new_version/validate" | jq -r '.status'`
  # Active it
  if [ "ok" = "$validate" ]; then
    local result=`curl -s -X PUT -H "X-Fastly-Key: $api" "https://api.fastly.com/service/$serviceid/version/$new_version/activate" | jq -r '.active'`
    if [ "true" = "$result" ]; then
      return 0
    fi
  fi
  return 1
}

do_update() {
  local api="$1"
  local serviceid="$2"
  local version=$(find_active_version "$api" "$serviceid")
  if add_backend "$api" "$serviceid" "$version" "$(get_private_ip)" "$(get_public_ip)"; then
    echo "Add succesfully and activate a new version after $version"
  else
    echo "Fail to add this server"
  fi
}

cleanup_dead_service() {
  curl -s 127.0.0.1:8500/v1/catalog/service/lua-image | jq -r '.[] | select(.ServiceName == "lua-image") | .ServiceID' | grep -v `hostname` | xargs -I id curl -X POST 127.0.0.1:8500/v1/agent/service/deregister/id
}

# Fastly var are in env variables, which is created by cloud-init script
APIKEY="$FASTLY_APIKEY"
SERVICEID="$FASTLY_SERVICEID"

cleanup_dead_service

if [ -z "$APIKEY" ]; then
  echo "Missing APIKey"
  exit 0
fi

(need_update "$APIKEY" "$SERVICEID" && do_update "$APIKEY" "$SERVICEID") || echo "No update is need"
echo "Autoscaling always return 0 as succesfully."
exit 0
