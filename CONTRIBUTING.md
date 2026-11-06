<!--
SPDX-FileCopyrightText: 2026 Netbeheer Nederland

SPDX-License-Identifier: Apache-2.0
-->

# How to contribute

We'd love to accept your patches and contributions to this project. There are just a few guidelines you need to follow.

This repository holds the deployment and demo material for the rti-demo: Docker Compose, the VM fleet setup, Helm
charts and ArgoCD applications, scripts and playbooks. The application code (HMI, BFF, SO, FSP and the plugins) lives
in [iec61850-websocket](https://github.com/netbeheernederland/iec61850-websocket); changes to it go there.

## Ways of contributing

Contribution does not necessarily mean committing code to the repository.
We recognize different levels of contributions as shown below in increasing order of dedication.

1. Use and test the demo. Give feedback on the user experience or suggest new features.
2. Report bugs or security vulnerabilities.
3. Fix bugs.
4. Improve the demo by adding deployment targets, playbooks or documentation.

## Filing bugs, security vulnerabilities, or feature requests

You can file bugs against and feature requests for the demo via GitHub Issues.
Read [GitHub Help](https://docs.github.com/en/issues/tracking-your-work-with-issues/creating-an-issue)
for more information on using GitHub Issues. A bug in one of the services themselves belongs in the issues of
[iec61850-websocket](https://github.com/netbeheernederland/iec61850-websocket/issues).

If you think you've found a potential vulnerability in this project, please
email <rti@netbeheernederland.nl> to responsibly disclose it.

## Community guidelines

This project follows the following [Code of Conduct](CODE_OF_CONDUCT.md).

## Licensing and source code headers

The project is licensed under the [Apache License 2.0](LICENSE). The license texts are in `LICENSES/`.

A new file that can carry a comment starts with the Apache 2.0 header, in the comment syntax of the file (use the
current year):

```text
SPDX-FileCopyrightText: 2026 Netbeheer Nederland
SPDX-License-Identifier: Apache-2.0
```

`uvx reuse annotate --copyright "Netbeheer Nederland" --license Apache-2.0 <file>` adds it for you.

## Git branching

`main` is the default branch and holds the latest reviewed state. Work happens on topic branches with a short,
descriptive name (for example `compose-node-scaling`) and reaches `main` through a pull request.

## Signing the Developer Certificate of Origin (DCO)

This project uses a Developer Certificate of Origin (DCO) to ensure that each commit was written by the author or that
the author has the appropriate rights necessary to contribute the change.
Specifically, we use [Developer Certificate of Origin, Version 1.1](http://developercertificate.org/), which is the same
mechanism that the Linux® Kernel and many other communities use to manage code contributions.
The DCO is considered one of the simplest tools for sign-offs from contributors as the representations are meant to be
straightforward to read and indicating signoff is done as a part of the commit message.

This means that each commit must include a DCO which looks like this:

`Signed-off-by: Joe Smith <joe.smith@email.com>`

The project requires that the name used is your real name and the e-mail used is your real e-mail.
Neither anonymous contributors nor those utilizing pseudonyms will be accepted.

There are other great tools out there to manage DCO signoffs for developers to make it much easier to do signoffs:

* Git makes it easy to add this line to your commit messages. Make sure the `user.name` and `user.email` are set in your
  git configs. Use `-s` or `--signoff` to add the Signed-off-by line to the end of the commit message.
* [GitHub UI automatic signoff capabilities](https://github.blog/changelog/2022-06-08-admins-can-require-sign-off-on-web-based-commits/)
  for adding the signoff automatically to commits made with the GitHub browser UI. This one can only be activated by the
  GitHub org or repo admin.
* Alternatively, you can add a `prepare-commit-msg` hook in the `.git/hooks` directory that adds the line with
  `git interpret-trailers`.

## Code reviews

All patches and contributions, including patches and contributions by project members, require review by one of the
maintainers of the project.
We use GitHub pull requests for this purpose.
See [GitHub Help](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/about-pull-requests)
for more information on using pull requests.

## Pull request process

Contributions should be submitted as GitHub pull requests.
See [Creating a pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request)
if you're unfamiliar with this concept.

Follow this process for a change and pull request:

1. Create a topic branch in your local repository with a short, descriptive name (see [Git branching](#git-branching)).
1. Make your changes and try them on the deployment target they affect: the single-host Docker Compose stack, the VM
   fleet in `setup/`, or Kubernetes with `deploy/`. Keep changes focused on the topic of the pull request, and match the
   existing style and conventions.
1. Check what you changed before you push, for example `docker compose config -q` for `docker-compose.yml`,
   `helm lint` for a chart in `deploy/helm`, and `scripts/validate-keycloak-authz.sh` for the Keycloak setup.
1. Update the documentation your change affects: the README, `docs/`, and a decision record in `docs/decisions/` for a
   design decision.
1. Push commits to your branch.
1. Create a GitHub pull request from your topic branch.
1. Pull requests will be reviewed by one of the maintainers who may discuss, offer constructive feedback, request
   changes, or approve the work. See [Code reviews](#code-reviews).
1. Upon receiving the sign-off from one of the maintainers you may merge your changes. If you do not have permission to
   do that, you may request a maintainer to merge it for you.

## Attribution

This CONTRIBUTING.md is adapted from Google, available
at https://github.com/google/new-project/blob/master/docs/contributing.md.
