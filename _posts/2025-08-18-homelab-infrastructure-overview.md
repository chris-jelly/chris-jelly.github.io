---
title: "Homelab Infrastructure Overview"
date: 2025-08-18 07:34:14 -0400
categories: [homelab]
tags: [kubernetes, infrastructure, homelab, data-engineering]
---


## Homelab Intro / (Why?)
I enjoy learning new technologies, partially to satiate my own curiousity but also to make myself a better [t-shaped professional](https://en.wikipedia.org/wiki/T-shaped_skills). Over the years I have dabbled in many things:
Learning programming, infrastructure as code, data engineering, etc. In January of 2025 I started to learn about Kubernetes, an open source system for automating and managing containerized applications. In this I saw an opportunity
to have a playground where I can string all of these skills together, own the whole process and get into the weeds where learning happens. I joined a devops focused community ([KubeCraft](https://www.skool.com/kubecraft/about?ref=242c587e51bb4f9a9abab62bc823d80e)),
and threw together a homelab out of a raspberry Pi and some old laptops. What follows here is the gist of the setup, though it'll surely change as my requirements do. 

The configuration is all public, You can find my homelab repository here: [Homelab](https://github.com/chris-jelly/homelab)

## The Software Stack

### Kubernetes Distribution

At present I am running [K3S](https://k3s.io/). It's light-weight which is ideal for my resource limited setup, is easy to install, and is a more streamlined experience compared to some other options. Later I'll likely switch to [Talos](https://www.talos.dev/) 
to make it simpler to re-deploy the cluster from scratch. Just need to run those ethernet cables...

### GitOps with FluxCD

The folks at KubeCraft pushed me to jump to GitOps management for my repository from the get-go, the idea of which is to
declare the configuration in version control, then use a Kubernetes Operator such as Flux or ArgoCD to apply it. This was a steeper learning curve to get over, but the result is very satisfying to build in as it is easier to iteratively build out
the configuration. The tool suggested by Mischa was Flux, and I've not had cause to switch from it yet.  
The folder structure breaks down as such:

```
├── apps/           # Application deployments with Kustomize overlays
├── infrastructure/ # Core components (cert-manager, external-secrets, etc.)
├── monitoring/     # Observability stack (Prometheus, Grafana)
├── databases/      # Database configs using CloudNative-PG
└── clusters/       # Cluster-specific Flux configurations
```

### Infrastructure & Operations

- Cert-Manager: [SSL certificate automation]
- External Secrets Operator: [Sync Secrets from secret providers (Azure Key Vault for me)]
- Renovate: [Automated dependency updates]
- Monitoring Stack: [Prometheus + Grafana setup]
- CloudNative-PG: [PostgreSQL databases in Kubernetes]


## How this all works

I'm skipping details for the sake of brevity, but the general flow of how the cluster and applications are deployed is as follows:

1. Deploy K3S cluster
2. Install Flux in the cluster
3. Flux deploys resources

This really opens the door to build and deploy much more robust applications. I can now write an application, containerize it, then deploy that image to my cluster, all largely automated. Just as important,
it's all version controlled so you can see what changed, when, and hopefully get to why. How cool is that?
