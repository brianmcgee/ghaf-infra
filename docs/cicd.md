# CI/CD 

The following is an overview of the various aspects of the CI/CD architecture for [Ghaf](https://github.com/tiiuae/ghaf).

Its goal is to be as agnostic as possible with respect to source forges, cloud providers and more. 

Where specific choices have been made (e.g. [Jenkins](https://www.jenkins.io/)) it is worth remembering that most of the
heavy lifting is being done within [Nix](https://nixos.org), and special care will be taken to avoid relying too heavily
on vendor-specific functionality. 

## Overview

The [Ghaf](https://github.com/tiiuae/ghaf) project currently consists of _~52_ build targets per architecture
(e.g. `x86_64-linux`, `aarch64-linux` and so on).

Within those build targets, the major causes of mass rebuilds is a patch to systemd, a low-level component in the build 
tree. This causes all downstream packages to differ from the ones already in cache.nixos.org.

However, these rebuilds only need to happen whenever that part of the build graph changes, which is either during bumps 
of `nixpkgs` itself that touch it, or work on that patch itself.

Most of the time, during day to day operations, the amount of actual rebuilds should be fairly small.

Upstreaming this change to nixpkgs (as has been attempted in https://github.com/NixOS/nixpkgs/pull/239201, but which 
needs to be brought to the finish line) will remove the need for rebuilding this package so deep in the tree and all of 
it dependencies (looking at you Firefox).

> - Hydra is meant to orchestrate a massive amount of attributes (217,000 for nixpkgs vs 52x2 for ghaf) with complex build 
trees that require partitioning and distribution across multiple builders for the same architecture.
> - Even with the current whenever-nixpkgs-is-bumped rebuilds, the build workloads can be done by a single worker in a reasonable amount of time.
> - Therefore, there is no need for all the additional complexity that hydra brings.
> - Hydra is _not actively maintained_. For some context [here is a discussion](https://discourse.nixos.org/t/nixcon-governance-workshop/32705/11) 
that was had at NixCon 2023 which touches on the state of Hydra.
> - We'd be better off invoking [nix-fast-build](https://github.com/Mic92/nix-fast-build) with `-f #.packages.x86_64-linux` 
and `-f #.packages.aarch64-linux` on two separate build machines. 

## Removing Hydra

At a high level, a release consists of the following build steps:

1. A new tag / release is created within source control. This is detected and a build pipeline is triggered.
2. The first of those build steps is a Nix build, ensuring all packages and NixOS configurations complete successfully, 
and for all required architectures.
3. After completing the Nix build, various vulnerability scans can be applied (outside the Nix build) using [sbomnix](https://github.com/tiiuae/sbomnix).
4. Finally, and perhaps also _concurrently_ with step 3, testing on specific types of hardware can be carried out.

> To begin with this pipeline can be triggered upon release, but there's nothing preventing it from being 
> triggered for each PR or on push if desirable. 

![](./assets/stages.svg)

## Nix Build

A Nix build may require building packages for multiple architectures, e.g. `x86_64-linux` and `aarch64-linux`. 

To support this, a series of NixOS-based build servers will be used, and be configured as [Remote Builders](https://nixos.org/manual/nix/stable/advanced-topics/distributed-builds) 
for the Nix Daemon running on the Jenkins Master machine. The build graph for a given build job will be resolved by the
Jenkins Master's Nix daemon and then distributed via the remote builder protocol to the build agents based on their 
system architectures and capabilities.  

> As required, more remote builders can be added to scale out total build capacity and to support new architectures. 

In special cases where the remote builder protocol is not appropriate, a [Jenkins build agent](https://www.jenkins.io/doc/book/using/using-agents/) 
can be run which will co-ordinate with the Jenkins Master. The Jenkins agent process itself will be run as an 
_untrusted user_ as far as the Nix Daemon is concerned. Whilst it can trigger Nix builds, it does not have access to 
the signing key, and it can only make store paths appear by triggering builds (input-addressed), or importing 
content-addressed contents.

For signing store paths, we will rely upon a [post-build-hook](https://nixos.org/manual/nix/stable/advanced-topics/post-build-hook), which runs in the context of the Nix Daemon. This 
allows configuring a (Nix) post-build step which can sign store paths and push them to a [Binary Cache](https://nixos.wiki/wiki/Binary_Cache), making 
those store paths available for substitution on other systems. 

The signing key used by the post-build-hook will _only be accessible_ to the `root` user and Nix Daemon. It will need to
be accessible on every build machine and kept secure. 

![](./assets/build.svg)

## Vulnerability Scanning

Automated vulnerability scanning can be done once a Nix build has completed for a given architecture. This is carried 
out by [sbomnix](https://github.com/tiiuae/sbomnix) and typically, but not always, requires the Nix build to have completed first. 

This will be facilitated via the aforementioned Binary cache, and therefore does not require the vulnerability scanning 
to be carried out on the same build machine as the Nix build. The _only requirement_ is that the target architecture matches. 

The resultant scan artefacts must then be signed (the exact mechanism is still being discussed) and made available for 
download. This can be done via Jenkins, or the artefacts can be uploaded to some blob storage, or perhaps even both. 

> It's worth noting that vulnerability scanning is *not a singular event*. 
> 
> When a new release is produced an initial scan result is required. However, over time, we want to periodically re-run 
> the scan to detect any new vulnerabilities. 
> 
> This can be carried out via a scheduled (nightly, weekly, etc.) build pipeline and leverage the cached store paths
> from the Binary Cache. 

![](./assets/scan.svg)

## SLSA

The long term goal for the CI/CD setup is to be SLSA Level 3 compliant. Let us examine each SLSA requirement in turn 
and explore how it will be met. 

> The following requirements have been taken from https://slsa.dev/spec/v0.1/requirements

### 1 Scripted Build

> All build steps were fully defined in some sort of “build script”. The only manual command, if any, was to invoke the 
> build script.

All builds will be defined a Nix derivations using the Nix language. 

### 2 Build Service

> All build steps ran using some build service, not on a developer’s workstation.

This project and the architecture described above addresses this need directly, providing a CI/CD infrastructure for 
running development and production builds independent of developer workstations.

### 3.1 Build As Code

> The build definition and configuration executed by the build service is verifiably derived from text file definitions 
> stored in a version control system.

All builds are defined with Nix and stored within source control. Nix further ensures that whenever a dependency has been
changed a rebuild is required through its use of input-addressing. 

For example, if the underlying `src` for a derivation were to change, this would be reflected in the hash component of 
it's output path. Any dependent store paths are then required to be re-built.

### 3.2 Ephemeral Environment

> The build service ensured that the build steps ran in an ephemeral environment, such as a container or VM, provisioned 
> solely for this build, and not reused from a prior build.

For development builds, it can be deemed acceptable to retain long-lived instances of the Jenkins Master and the remote
builders. 

For production builds however, and in order to reduce the attack surface, it is desirable to have the entire build 
environment be created, run the builds, and then tore down. 

This should be possible with a combination of Terraform, NixOS-based images, VM services in a given cloud provider,
declarative specification of Jenkins build jobs, and some scripting on top to glue all of this together. 

Longer-term it is worth looking into alternative solutions such as micro vms or container services.

### 3.3 Isolated

> The build service ensured that the build steps ran in an isolated environment free of influence from other build 
> instances, whether prior or concurrent.

> It MUST NOT be possible for a build to access any secrets of the build service, such as the provenance signing key.

TODO check with Florian wrt latest iteration of the arch

> It MUST NOT be possible for two builds that overlap in time to influence one another.
> It MUST NOT be possible for one build to persist or influence the build environment of a subsequent build.

All Nix builds are executed within a [chroot](https://en.wikipedia.org/wiki/Chroot)-based environment, with additional
measures taken by the Nix Daemon to ensure a pure build environment. That being said, more could be done to harden this
default setup. 

> Build caches, if used, MUST be purely content-addressable to prevent tampering.

Currently Nix build caches are input-addressed, not content-addressed. There are a variety of ongoing efforts within the
community with respect to content-addressable store paths and binary caches.

To mitigate this in the short-term, it is recommended that any build outputs be cross-compared between 2 or more 
independent production builds. This should detect any issues with reproducibility as well as catching instances of build
cache tampering. 

Such a comparison is recommended regardless of the introduction of content-addressable store paths as an ongoing measure
to detect tampering. 

### 4.1 Hermetic

Whilst not currently part of the Level 3 specification, it is expected in the future that hermetic builds will be 
re-introduced as a requirement. Without going into too much detail, it is believed that the Nix build environment meets
a lot of the requirements out of the box. 

Any areas where it currently does not can be remediated with improvements to the Nix build environment or by developing
a custom builder which uses micro vms or containers, for which there are already some efforts underway. 

### 4.2 Reproducibility

Nix was designed with reproducibility in mind, however it is up those writing Nix derivations to ensure their build 
outputs are bit-wise the same. For example Gradle does not provide bit-wise reproducible outputs unless certain options 
are enabled. 

There is a mechanism within Nix which can be used to test if a build is reproducible: `nix build --rebuild ...`. This 
can be used within the CI jobs to automate detection of non-reproducible builds. 

In addition, cross-comparison of production build outputs should help to catch these. If all builds are reproducible,
however two production builds have different contents, then tampering is the next logical thing to consider. 

## Hardware Testing

TBD