# Copy to platform/env.sh (git-ignored), edit, then: source platform/env.sh
export AWS_PROFILE=<your-admin-profile>
export REGION=us-east-2
export CLUSTER=restate-argocd-eks
export NAMESPACE=team-a
export BUCKET=restate-argocd-eks-snapshots-<suffix>   # must match restate/values-team-a.yaml
export WORKLOAD_SA=restate-workload                    # must match restate/values-team-a.yaml
export REPO=git@github.com:jgrier/restate-argocd-eks.git
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
# Which IAM principal may assume joe's role (e.g. your SSO admin role ARN pattern):
export JOE_ASSUMER_ARN="arn:aws:iam::${ACCOUNT_ID}:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_AdministratorAccess_*"
