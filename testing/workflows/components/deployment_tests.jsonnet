local params = std.extVar("__ksonnet/params").components.deployment_tests;

local k = import "k.libsonnet";
local util = import "workflows.libsonnet";

// TODO(jlewi): Can we get namespace from the environment rather than
// params?
local namespace = params.namespace;

local name = params.name;

local prowEnv = util.parseEnv(params.prow_env);
local bucket = params.bucket;

// mountPath is the directory where the volume to store the test data
// should be mounted.
local mountPath = "/mnt/" + "test-data-volume";
// testDir is the root directory for all data for a particular test run.
local testDir = mountPath + "/" + name;
// outputDir is the directory to sync to S3 to contain the output for this job.
local outputDir = testDir + "/output";
local artifactsDir = outputDir + "/artifacts";
// Source directory where all repos should be checked out
local srcRootDir = testDir + "/src";
// The directory containing the kubeflow/kubeflow repo
local srcDir = srcRootDir + "/kubeflow/kubeflow";

local image = "527798164940.dkr.ecr.us-west-2.amazonaws.com/aws-kubeflow-ci/test-worker:latest";
local testing_image = "527798164940.dkr.ecr.us-west-2.amazonaws.com/aws-kubeflow-ci/test-worker:latest";

// The name of the NFS volume claim to use for test files.
local nfsVolumeClaim = "nfs-external";
// The name to use for the volume to use to contain test data.
local dataVolume = "kubeflow-test-volume";
local kubeflowPy = srcDir;
// The directory within the kubeflow_testing submodule containing
// py scripts to use.
local kubeflowTestingPy = srcRootDir + "/kubeflow/testing/py";

// the name of EKS cluster to use in the test
// AI: Need to be randomized
local cluster = params.cluster_name;

// Build an Argo template to execute a particular command.
// step_name: Name for the template
// command: List to pass as the container command.
// We use separate kubeConfig files for separate clusters
local buildTemplate(step_name, command, working_dir=null, env_vars=[], sidecars=[]) = {
  name: step_name,
  activeDeadlineSeconds: 1800,  // Set 30 minute timeout for each template
  workingDir: working_dir,
  container+: {
    command: command,
    image: image,
    workingDir: working_dir,
    // TODO(jlewi): Change to IfNotPresent.
    imagePullPolicy: "Always",
    env: [
      {
        // Add the source directories to the python path.
        name: "PYTHONPATH",
        value: kubeflowPy + ":" + kubeflowTestingPy,
      },
      {
        // EKS cluster name
        name: "CLUSTER_NAME",
        value: cluster,
      },
      {
        name: "DESIRED_NODE",
        value: "2",
      },
      {
        name: "MIN_NODE",
        value: "1",
      },
      {
        name: "MAX_NODE",
        value: "4",
      },
      {
          // EKS Namespace
          name: "EKS_NAMESPACE",
          value: namespace,
      },
      {
        name: "GITHUB_TOKEN",
        valueFrom: {
          secretKeyRef: {
            name: "github-token",
            key: "github_token",
          },
        },
      },
      {
        name: "AWS_ACCESS_KEY_ID",
        valueFrom: {
          secretKeyRef: {
            name: "aws-credentials",
            key: "AWS_ACCESS_KEY_ID",
          },
        },
      },
      {
        name: "AWS_SECRET_ACCESS_KEY",
        valueFrom: {
          secretKeyRef: {
            name: "aws-credentials",
            key: "AWS_SECRET_ACCESS_KEY",
          },
        },
      },
      {
        name: "AWS_DEFAULT_REGION",
        value: "us-west-2",
      },
    ] + prowEnv + env_vars,
    volumeMounts: [
      {
        name: dataVolume,
        mountPath: mountPath,
      },
    ],
  },
  sidecars: sidecars,
};  // buildTemplate


// Create a list of dictionary.c
// Each item is a dictionary describing one step in the graph.
local dagTemplates = [
  {
    template: buildTemplate("create-eks-cluster",
                            ["/usr/local/bin/create-eks-cluster.sh"]), // create-eks-cluster
    dependencies: null,
  },
  {
    template: buildTemplate("deploy-kubeflow",
                            ["/usr/local/bin/deploy-kubeflow.sh"]), // deploy-kubeflow
    dependencies: ["create-eks-cluster"],
  },
  {
    template: buildTemplate("check-load-balancer-status",
                            ["/usr/local/bin/check-load-balancer-status.sh"]), // check-deployment-status
    dependencies: ["deploy-kubeflow"],
  },
];

// Each item is a dictionary describing one step in the graph
// to execute on exit
local exitTemplates = [
  {
    template: buildTemplate("delete-eks-cluster",
                            ["/usr/local/bin/delete-eks-cluster.sh"]), // delete-eks-cluster
    dependencies: null,
  },
];

// Dag defines the tasks in the graph
local dag = {
  name: "e2e",
  // Construct tasks from the templates
  // we will give the steps the same name as the template
  dag: {
    tasks: std.map(function(i) {
      name: i.template.name,
      template: i.template.name,
      dependencies: i.dependencies,
    }, dagTemplates),
  },
};  // dag

// The set of tasks in the exit handler dag.
local exitDag = {
  name: "exit-handler",
  // Construct tasks from the templates
  // we will give the steps the same name as the template
  dag: {
    tasks: std.map(function(i) {
      name: i.template.name,
      template: i.template.name,
      dependencies: i.dependencies,
    }, exitTemplates),
  },
};

// A list of templates for the actual steps
local stepTemplates = std.map(function(i) i.template
                              , dagTemplates) +
                      std.map(function(i) i.template
                              , exitTemplates);


// Add a task to a dag.
local workflow = {
  apiVersion: "argoproj.io/v1alpha1",
  kind: "Workflow",
  metadata: {
    name: name,
    namespace: namespace,
    labels: {
      org: "kubeflow",
      repo: "kubeflow",
      workflow: "e2e",
      // TODO(jlewi): Add labels for PR number and commit. Need to write a function
      // to convert list of environment variables to labels.
    },
  },
  spec: {
    entrypoint: "e2e",
    volumes: [
      {
        name: dataVolume,
        persistentVolumeClaim: {
          claimName: nfsVolumeClaim,
        },
      },
    ],  // volumes
    // onExit specifies the template that should always run when the workflow completes.
    onExit: "exit-handler",
    templates: [dag, exitDag] + stepTemplates,  // templates
  },  // spec
};  // workflow

std.prune(k.core.v1.list.new([workflow]))
