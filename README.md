# Azure Terraform Platform Lab
## In this project, I am architecting an environment that simulates the processes corporate environments use to deploy Infrastructure as Code (IaC)
- Utilizing Github Actions, we can implement an automated CI/CD pipeline that double-checks our Terraform code and highlights errors within our deployments
- A pull request gets created with every push action. Said pull request can then be reviewed by a senior engineer, approved and then deployed to the actual dev environment resource group in Azure
- The pipeline uses OIDC federated authentication so that we store no long-lived secrets for communication.

## This repo is still an active work in progress
- What is to come: App Gateway/WAF, VM Scale Set, Key Vault, and private-endpoint PostGreSQL

# Why this project exists

I built this to get real, hands-on experience with the same patterns used in production cloud environments: modular IaC, environment separation (dev/prod), and a CI/CD pipeline that enforces validation before anything touches live infrastructure. Rather than just study Azure concepts for AZ-104, I wanted to prove them out end-to-end — write the Terraform, break the pipeline, fix it, and understand why it broke.

# CI/CD Pipeline

The pipeline is built on two GitHub Actions workflows that separate validation from deployment — a deliberate choice to make sure nothing gets applied to Azure without first passing checks in an open pull request.

## 1. PR Checks (terraform-pr.yml)

Triggered on every pull request targeting main. This workflow:

Authenticates to Azure via OIDC (see below)
Runs terraform fmt -check to enforce formatting standards
Runs terraform init and terraform validate
Runs terraform plan so reviewers can see exactly what will change before approving

Nothing gets applied here — it's read-only validation, which means a bad plan gets caught in review instead of in production.

## 2. Terraform Apply (terraform-apply.yml)

Triggered only on push to main (i.e., after a PR is merged), and scoped to only run when files under environments/dev/** or modules/** change. This workflow runs the full init → validate → plan → apply sequence and actually provisions the infrastructure.

Authentication: OIDC over long-lived secrets

Both workflows authenticate to Azure using OpenID Connect (OIDC) federated credentials instead of a stored client secret. GitHub Actions requests a short-lived token from GitHub's OIDC provider, which Azure AD trusts based on a federated credential scoped to this specific repo and branch. The practical benefit: no Azure secret sits in GitHub at all — nothing to rotate, nothing to leak.

# Challenges & what I learned

Getting OIDC working end-to-end surfaced a handful of real debugging problems — the kind you don't run into just reading documentation:

Federated credential subject mismatch: Azure AD federated credentials are matched by an exact subject claim string. GitHub Actions lowercases environment names in that claim regardless of how the environment is capitalized in the repo settings — so a federated credential configured with mixed case silently never matches, and the login step fails with an unhelpful generic auth error. Fixed by aligning the federated credential's subject to the lowercased form GitHub actually sends.
RBAC scope: the service principal needs explicit role assignments at the right scope (subscription or resource group) — OIDC handles authentication, but authorization is a separate, deliberate step.
Directory casing issues: renamed a directory to fix a casing mismatch between local and remote using git mv specifically, since a plain OS-level rename doesn't reliably propagate case changes through Git on case-insensitive filesystems.


Debugging this taught me to think about CI/CD pipelines the way I'd think about a network trace — following the request hop by hop (GitHub → OIDC token → Azure AD → RBAC check) to find exactly where the chain broke, rather than guessing at the whole system at once.

Tech stack


Terraform — infrastructure as code
GitHub Actions — CI/CD orchestration
Azure OIDC / Workload Identity Federation — secretless authentication
Azure — target cloud platform (networking, storage; more modules in progress)
