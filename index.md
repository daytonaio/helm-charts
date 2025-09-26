# Kubernetes Helm Charts
[![License](https://img.shields.io/badge/License-Elastic--2.0-blue)](#license)

The code is provided as-is with no warranties.

## Usage
[Helm](https://helm.sh) must be installed to use the charts.
Please refer to Helm's [documentation](https://helm.sh/docs/) to get started.

Once Helm is set up properly, add the repo as follows:

```console
helm repo add daytonaio https://charts.daytona.io
```

You can then run `helm search repo daytonaio` to see the charts.

## License
This repository contains the Daytona Enterprise Demo installer, covered under the [Elastic License 2.0](LICENSE), except where noted (any Daytona logos or trademarks are not covered under the Elastic License, and should be explicitly noted by a LICENSE file.)

Others are allowed to make their own distribution of the software in this repository under the license, but they cannot use any of the Daytona trademarks, cloud services, etc.

We explicitly grant permission for you to make a build that includes our trademarks while developing Daytona itself. You may not publish or share the build, and you may not use that build to run Daytona for any other purpose.
