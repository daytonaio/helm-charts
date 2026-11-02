# Private proxy ingress

The proxy does not need a public ingress. Daytona Cloud does not connect to it:
every connection between your region and Daytona Cloud is outbound HTTPS from
your cluster. The proxy only has to be reachable by the people and programs
that open previews or call the toolbox API, so you can put it behind an
internal load balancer that only your network (VPN, peering, private link)
reaches.

A private ingress narrows who can reach the proxy. It does not replace preview
authentication, which stays on either way (see
[Preview authentication](../charts/daytona-region/README.md#preview-authentication)).

This page covers the proxy ingress. The SSH gateway is a separate
`LoadBalancer` Service (`services.sshGateway.service`); make it internal with
the same cloud annotations as below if your SSH clients are on the private
network too.

## Before you switch

Check these three things first. Each one is a common reason a private region
stops working.

1. **Outbound access to the Daytona API.** The proxy, the registration hook,
   the runner-manager and the runners call `daytonaApiUrl` over HTTPS. A
   private ingress does not change that: the cluster still needs egress to the
   Daytona API, through NAT or an outbound proxy. If you use an outbound
   proxy, give the proxy pod `HTTPS_PROXY` and `NO_PROXY` through
   `services.proxy.extraEnv`:

   ```yaml
   services:
     proxy:
       extraEnv:
         - name: HTTPS_PROXY
           value: "http://egress-proxy.internal:3128"
         - name: NO_PROXY
           value: ".svc,.cluster.local"
   ```

   The proxy fetches its configuration from the API at startup and exits if it
   still cannot after retrying, so a missing egress path shows up as a proxy
   pod that restarts.

2. **Who calls `/toolbox`.** The SDK, the CLI and the Daytona dashboard's
   terminal and file views connect to `<proxyUrl>/toolbox` directly from the
   machine they run on. With a private ingress, those machines need a network
   path to it. A browser on the Daytona dashboard outside your network gets a
   connection error for those views, and an SDK script running outside your
   network cannot reach the sandbox's toolbox.

3. **TLS certificates.** Let's Encrypt's HTTP-01 challenge needs to reach the
   ingress from the internet, so it does not work on a private ingress. Use
   one of these instead:
   - a DNS-01 ClusterIssuer (it also issues the `*.<proxy-host>` wildcard; set
     `services.proxy.ingress.wildcardTls: true`), see the
     [DNS-01 wildcard upgrade path](troubleshooting.md#dns-01-wildcard-upgrade-path);
   - a certificate from your own CA in `services.proxy.ingress.secrets`;
   - on AWS, an ACM certificate on the ALB (example below).

   The DNS records for `<proxy-host>` and `*.<proxy-host>` can live in a
   private zone, as long as every client resolves them.

Keep long-lived connections working: previews, terminals and the toolbox use
WebSockets, so set the load balancer's idle timeout and the ingress read and
send timeouts to 3600 seconds, as the cloud values templates do.

## AWS: internal ALB

With the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
installed, use the `alb` ingress class with an internal scheme and an ACM
certificate that covers `<proxy-host>` and `*.<proxy-host>`:

```yaml
services:
  proxy:
    ingress:
      enabled: true
      className: alb
      # TLS terminates on the ALB with the ACM certificate below.
      tls: false
      annotations:
        alb.ingress.kubernetes.io/scheme: internal
        alb.ingress.kubernetes.io/target-type: ip
        alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS":443}]'
        alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:<region>:<account>:certificate/<id>
        alb.ingress.kubernetes.io/load-balancer-attributes: idle_timeout.timeout_seconds=3600
```

`proxyUrl` stays `https://<proxy-host>`.

To keep ingress-nginx instead, make its controller Service internal when you
install ingress-nginx (not in this chart), then use the same daytona-region
values as the Azure example below:

```yaml
# ingress-nginx values
controller:
  service:
    annotations:
      # Load balancer created by the in-tree AWS cloud provider:
      service.beta.kubernetes.io/aws-load-balancer-internal: "true"
      # Or, with the AWS Load Balancer Controller managing the Service:
      # service.beta.kubernetes.io/aws-load-balancer-type: external
      # service.beta.kubernetes.io/aws-load-balancer-scheme: internal
```

## Azure: ingress-nginx on an internal load balancer (AKS)

Install ingress-nginx with an internal Azure load balancer, then keep this
chart's default `nginx` ingress class:

```yaml
# ingress-nginx values
controller:
  service:
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-internal: "true"
      # Optional: pin the load balancer to a subnet.
      # service.beta.kubernetes.io/azure-load-balancer-internal-subnet: <subnet-name>
```

```yaml
# daytona-region values
services:
  proxy:
    ingress:
      enabled: true
      className: nginx
      annotations:
        cert-manager.io/cluster-issuer: <your DNS-01 issuer>
        nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
        nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
      wildcardTls: true
```

## Google Cloud: ingress-nginx on an internal load balancer (GKE)

Install ingress-nginx with a GKE internal passthrough load balancer, then use
the same daytona-region values as the Azure example:

```yaml
# ingress-nginx values
controller:
  service:
    annotations:
      networking.gke.io/load-balancer-type: "Internal"
```

## Check it

From a machine on the private network:

```bash
curl -s https://<proxy-host>/health
```

The response includes `"status":"ok"`. From outside the network the host
should not resolve or connect.
