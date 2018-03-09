# kubecfn
*Cloudformation based installer for reasonably secure multi-node kubeadm
cluster.*

## Status
This still has some rough edges, see the issue. There are still issues
requiring manual intervention but it's designed to fail graceful in these
cases. The rolling upgrades of the masters use the
[WaitOnResourceSignals](https://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/aws-attribute-updatepolicy.html)
UpdatePolicy and scripts to ensure it only continues with the rollout of
the cluster is heathly.

We try to be reasonably secure, meaning all components are secured via TLS
and RBAC is enabled. Yet, due to the user-data size limits we need to fetch
the TLS keys from a S3 bucket. The permission for this is granted as an IAM
instance profile, that means you need to deploy kube2iam or something else
to block access to the metadata service. This isn't ideal but following the
current best practices.

## Operations
You can either edit the Makefile or use environment variable to override
specific settings.

- After deploying the cluster, you need to install kube2iam. Set your AWS
  account ID in [manifests/kube2iam.yaml](manifests/kube2iam.yaml) and apply the
  manifest.

## Known issues / README FIRST / FIXME
- Run all kubeadm generation steps in the Docker container (if in doubt, run
  all). This is required since `kubeadm alpha phase kubeconfig` has hardcoded
  file locations.

- When deleting the stack, it will fail to delete the hosted zone because we
  created DNS records from the lambda. In this case delete the records manually
  and retry deletion. (https://github.com/itskoko/kubecfn/issues/1)

- Same is true for cloud-provider-integration managed resources like ELBs. These
  should be deleted in kubernetes first. If that's not possible, the resources
  need to be deleted manually so cloudformation deletion can finish. (https://github.com/itskoko/kubecfn/issues/1)

- On rolling upgrades etcd-members are suppose to remove themself from the
  cluster. This isn't working reliably yet. If this happens, the new replacement
  node can't join the cluster. This will block the rollout. In this case make
  sure the old node is actually terminated and remove it from the cluster with
  `/etc/etcdctl-wrapper member remove`. (https://github.com/itskoko/kubecfn/issues/2)

- Rolling upgrades for workers is disabled right now. When updating, kill the
  old instances manually. (https://github.com/itskoko/kubecfn/issues/3)

- Sometimes kubeadm fails, probably when it comes up before etcd reached quorum
  and fails (but can be restarted) https://github.com/itskoko/kubecfn/issues/4

- Sometimes ignition fails to get assets from s3 and reboots as a slow form or
  'retry': https://github.com/coreos/bugs/issues/2280

## Create cluster
- modify `config/example.json`, make sure to set ClusterState=new!
- `docker build -t cfn-make .`
- `docker run -e AWS_ACCESS_KEY_ID=xx -e AWS_SECRET_ACCESS_KEY=yy cfn-make \
    create-cluster`
- Wait for the cluster to come up and update it again. This will flip the
  *initial-cluster-state* flag in etcd, making sure that further updates can be
  rolled back and forward reliably:
- `docker run -e AWS_ACCESS_KEY_ID=xx -e AWS_SECRET_ACCESS_KEY=yy cfn-make \
    update-cluster`
- Install networking plugin:
- `kubectl apply -f manifests/kube-flanne.yaml`
- modify `config/example.json`, make sure to set ClusterState=existing,
  otherwise replaced etcd instances won't be able to join the cluster.

## "Dry run"
Cloudformation supports [Change
Sets](http://docs.aws.amazon.com/AWSCloudFormation/latest/UserGuide/using-cfn-updating-stacks-changesets-create.html)
which can be used to get the changes CloudFormation will do without actually
updating the stack.

Create ChangeSet:
```
docker run -e AWS_ACCESS_KEY_ID=.. -e AWS_SECRET_ACCESS_KEY=.. -v $PWD:/usr/src/ \
  cfn-make cloudformation OP=create-change-set OPTS=--change-set-name=test2
```

To view the change set run:
```
aws --region us-east-1 cloudformation describe-change-set \
   --stack-name int2 --change-set-name test2
```

## Create custom cluster
To create a second cluster, you need to override the name of the cloudformation
stack. This can be done with the NAME environment variable.
Since the stack uses a existing VPC but brings it's own subnets, the network
ranges need to be adjusted in the config.
