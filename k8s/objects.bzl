# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""An implementation of k8s_object for interacting with an object of kind."""

load(
    "@io_bazel_rules_docker//skylib:path.bzl",
    _get_runfile_path = "runfile",
)

load("@io_bazel_rules_k8s//k8s:object.bzl", "resolve")

def _runfiles(ctx, f):
  return "PYTHON_RUNFILES=${RUNFILES} ${RUNFILES}/%s" % _get_runfile_path(ctx, f)

def _runfiles_bash(ctx, f):
  return "${RUNFILES}/%s" % _get_runfile_path(ctx, f)

def _run_all_impl(ctx):
  if ctx.attr.namespace and ctx.attr.namespace_file:
    fail("you should choose one: 'namespace' or 'namespace_file'")

  files = []
  cluster_arg = ctx.attr.cluster
  cluster_arg = ctx.expand_make_variables("cluster", cluster_arg, {})
  if "{" in ctx.attr.cluster:
    cluster_file = ctx.new_file(ctx.label.name + ".cluster-name")
    resolve(ctx, ctx.attr.cluster, cluster_file)
    cluster_arg = "$(cat %s)" % _runfiles_bash(ctx, cluster_file)
    files += [cluster_file]

  context_arg = ctx.attr.context
  context_arg = ctx.expand_make_variables("context", context_arg, {})
  if "{" in ctx.attr.context:
    context_file = ctx.new_file(ctx.label.name + ".context-name")
    resolve(ctx, ctx.attr.context, context_file)
    context_arg = "$(cat %s)" % _runfiles_bash(ctx, context_file)
    files += [context_file]

  user_arg = ctx.attr.user
  user_arg = ctx.expand_make_variables("user", user_arg, {})
  if "{" in ctx.attr.user:
    user_file = ctx.new_file(ctx.label.name + ".user-name")
    resolve(ctx, ctx.attr.user, user_file)
    user_arg = "$(cat %s)" % _runfiles_bash(ctx, user_file)
    files += [user_file]

  namespace_file = None

  namespace_arg = ctx.attr.namespace
  namespace_arg = ctx.expand_make_variables("namespace", namespace_arg, {})
  if "{" in ctx.attr.namespace:
    namespace_file = ctx.new_file(ctx.label.name + ".namespace-name")
    resolve(ctx, ctx.attr.namespace, namespace_file)

  if ctx.file.namespace_file:
    namespace_file = ctx.file.namespace_file

  if namespace_file:
    namespace_arg = "$(cat %s)" % _runfiles_bash(ctx, namespace_file)
    files += [namespace_file]

  if namespace_arg:
    namespace_arg = "--namespace=\"" +  namespace_arg + "\""

  if ctx.executable.before_command:
    before_command = " ".join([_runfiles_bash(ctx, ctx.executable.before_command)] + ctx.attr.before_command_args)
    files += [ctx.executable.before_command]
    files += list(ctx.attr.before_command.default_runfiles.files)
  else:
    before_command = ''


  ctx.actions.expand_template(
      template = ctx.file._template,
      substitutions = {
          "%{before_command}": before_command,
          "%{resolve_statements}": ("\n" + ctx.attr.delimiter).join([
              "{executable} --cluster='{cluster}' --context='{context}' --user='{user}' {namespace} $@".format(
                executable=_runfiles(ctx, exe.files_to_run.executable),
                cluster=cluster_arg,
                context=context_arg,
                user=user_arg,
                namespace=namespace_arg
              )
              for exe in ctx.attr.objects
          ]),
      },
      output = ctx.outputs.executable,
  )

  runfiles = [obj.files_to_run.executable for obj in ctx.attr.objects]
  for obj in ctx.attr.objects:
    runfiles += list(obj.default_runfiles.files)
  runfiles += files

  return struct(runfiles = ctx.runfiles(files = runfiles))

_run_all = rule(
    attrs = {
        "before_command": attr.label(cfg = "host", executable=True),
        "before_command_args": attr.string_list(),
        "objects": attr.label_list(
            cfg = "target",
        ),
        "_template": attr.label(
            default = Label("//k8s:resolve-all.sh.tpl"),
            single_file = True,
            allow_files = True,
        ),
        "delimiter": attr.string(default = ""),
        "cluster": attr.string(mandatory = False),
        "context": attr.string(mandatory = False),
        "user": attr.string(mandatory = False),
        "namespace": attr.string(mandatory = False),
        "namespace_file": attr.label(allow_single_file=True, mandatory = False),
    },
    executable = True,
    implementation = _run_all_impl,
)

def k8s_objects(name, objects, **kwargs):
  """Interact with a collection of K8s objects.

  Args:
    name: name of the rule.
    objects: list of k8s_object rules.
  """

  # TODO(mattmoor): We may have to normalize the labels that come
  # in through objects.

  _run_all(name=name, objects=objects, delimiter="echo ---\n", **kwargs)
  _run_all(name=name + ".create", objects=[x + ".create" for x in objects], **kwargs)
  _run_all(name=name + ".delete", objects=[x + ".delete" for x in reversed(objects)], **kwargs)
  _run_all(name=name + ".replace", objects=[x + ".replace" for x in objects], **kwargs)
  _run_all(name=name + ".apply", objects=[x + ".apply" for x in objects], **kwargs)
