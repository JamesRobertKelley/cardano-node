# This script will load nix-built docker images of cardano-node
# into the Docker daemon (must be running), and then push to the
# Docker Hub. Credentials for the hub must already be installed with
# "docker login".
#
# There is a little bit of bash logic to replace the default repo and
# tag from the nix-build (../nix/docker.nix).
#
# 1. The repo (default "inputoutput/cardano-node") is changed to match
#    the logged in Docker user's credentials.
#
# 2. The tag (default "VERSION") is changed to reflect the
#    branch which is being built under this Buildkite pipeline.
#
#    - If this is a git tag build (i.e. release) then the docker tag
#      is left as-is.
#    - If this is a master branch build, then VERSION is replaced with
#      the git revision.
#    - Anything else is not tagged and not pushed.
#
# 3. After pushing the image to the repo, the "latest" tag is updated.
#
#    - "inputoutput/cardano-node:latest" should point to the most
#      recent VERSION tag build.
#    - "inputoutput/cardano-node:dev-master" should
#      point to the most recent master branch build.
#

{ walletPackages ?  import ../default.nix {}
, pkgs ? walletPackages.pkgs

# Build system's Nixpkgs. We use this so that we have the same docker
# version as the docker daemon.
, hostPkgs ? import <nixpkgs> {}

# Dockerhub repository for image tagging.
, dockerHubRepoName ? null
}:

with hostPkgs;
with hostPkgs.lib;

let
  images = map impureCreated [
    walletPackages.dockerImage
  ];

  # Override Docker image, setting its creation date to the current time rather than the unix epoch.
  impureCreated = image: image.overrideAttrs (oldAttrs: { created = "now"; }) // { inherit (image) version; };

in
  writeScript "docker-build-push" (''
    #!${runtimeShell}

    set -euo pipefail

    export PATH=${lib.makeBinPath [ docker gnused ]}

    ${if dockerHubRepoName == null then ''
    reponame=cardano-node
    username="$(docker info | sed '/Username:/!d;s/.* //')"
    fullrepo="$username/$reponame"
    '' else ''
    fullrepo="${dockerHubRepoName}"
    ''}

  '' + concatMapStringsSep "\n" (image: ''
    branch="''${BUILDKITE_BRANCH:-}"
    tag="''${BUILDKITE_TAG:-}"
    extra_tag=""
    if [[ -n "$tag" ]]; then
      tag="${image.imageTag}"
      extra_tag="latest"
    elif [[ "$branch" = master ]]; then
      tag="$(echo ${image.imageTag} | sed -e s/${image.version}/''${BUILDKITE_COMMIT:-dev-$branch}/)"
      extra_tag="$(echo ${image.imageTag} | sed -e s/${image.version}/dev-$branch/)"
    else
      echo "Not pushing docker image because this is not a master branch or tag build."
      exit 0
    fi
    echo "Loading ${image}"
    tagged="$fullrepo:$tag"
    docker load -i "${image}"
    if [ "$tagged" != "${image.imageName}:${image.imageTag}" ]; then
      docker tag "${image.imageName}:${image.imageTag}" "$tagged"
    fi
    echo "Pushing $tagged"
    docker push "$tagged"
    if [ -n "$extra_tag" ]; then
      echo "Pushing $fullrepo:$extra_tag"
      docker tag "$tagged" "$fullrepo:$extra_tag"
      docker push "$fullrepo:$extra_tag"
    fi
  '') images)
