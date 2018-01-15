# kubecfn
*Cloudformation based installer for reasonably secure multi-node kubeadm
cluster.*

# Operations
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
ranges need to be adjusted too:

```
docker run -e AWS_ACCESS_KEY_ID=.. -e AWS_SECRET_ACCESS_KEY=.. -v $PWD:/usr/src/ \
  cfn-make create-cluster NAME=int3 \
    PUBLIC_SUBNET_CIDR_PREFIX=172.20.15 \
    PRIVATE_SUBNET_CIDR_PREFIX=172.20.16
```
