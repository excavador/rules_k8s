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
    "@io_bazel_rules_docker//container:layer_tools.bzl",
    _get_layers = "get_from_target",
    _layer_tools = "tools",
)
load(
    "@io_bazel_rules_docker//skylib:label.bzl",
    _string_to_label = "string_to_label",
)
load(
    "@io_bazel_rules_docker//skylib:path.bzl",
    _get_runfile_path = "runfile",
)

def _runfiles(ctx, f):
  return "${RUNFILES}/%s" % _get_runfile_path(ctx, f)

def _deduplicate(iterable):
  """
  Performs a deduplication (similar to `list(set(...))`,
  but `set` is not available in Skylark).
  """
  return {k: None for k in iterable}.keys()

def _add_dicts(*dicts):
  """
  Creates a new dict with a union of the elements of the arguments
  """
  result = {}
  for d in dicts:
    result.update(d)
  return result

def _impl(ctx):
  """Core implementation of k8s_object."""

  all_inputs = []
  image_specs = []
  if ctx.attr.images:
    # Compute the set of layers from the image_targets.
    image_target_dict = _string_to_label(
        ctx.attr.image_targets, ctx.attr.image_target_strings)

    # Walk the collection of images passed and for each key/value pair
    # collect the parts to pass to the resolver as --image_spec arguments.
    # Each images entry results in a single --image_spec argument.
    # As part of this walk, we also collect all of the image's input files
    # to include as runfiles, so they are accessible to be pushed.
    for tag in ctx.attr.images:
      target = ctx.attr.images[tag]
      image = _get_layers(ctx, ctx.label.name, image_target_dict[target])

      image_spec = {"name": tag}
      if image.get("legacy"):
        image_spec["tarball"] = _runfiles(ctx, image["legacy"])
        all_inputs += [image["legacy"]]

      blobsums = image.get("blobsum", [])
      image_spec["digest"] = ",".join([_runfiles(ctx, f) for f in blobsums])
      all_inputs += blobsums

      blobs = image.get("zipped_layer", [])
      image_spec["layer"] = ",".join([_runfiles(ctx, f) for f in blobs])
      all_inputs += blobs

      image_spec["config"] = _runfiles(ctx, image["config"])
      all_inputs += [image["config"]]

      # Quote the semi-colons so they don't complete the command.
      image_specs += ["';'".join([
        "%s=%s" % (k, v)
        for (k, v) in image_spec.items()
      ])]

  image_chroot_arg = ctx.attr.image_chroot
  image_chroot_arg = ctx.expand_make_variables("image_chroot", image_chroot_arg, {})
  if "{" in ctx.attr.image_chroot:
    image_chroot_file = ctx.new_file(ctx.label.name + ".image-chroot-name")
    resolve(ctx, ctx.attr.image_chroot, image_chroot_file)
    image_chroot_arg = "$(cat %s)" % _runfiles(ctx, image_chroot_file)
    all_inputs += [image_chroot_file]

  if ctx.executable.before_command:
    before_command = " ".join([_runfiles(ctx, ctx.executable.before_command)] + ctx.attr.before_command_args)
    all_inputs += [ctx.executable.before_command]
    all_inputs += list(ctx.attr.before_command.default_runfiles.files)
  else:
    before_command = ''

  ctx.actions.expand_template(
      template = ctx.file._template,
      substitutions = {
        "%{before_command}": before_command,
        "%{resolver}": _runfiles(ctx, ctx.executable.resolver),
        "%{yaml}": _runfiles(ctx, ctx.file.template),
        "%{image_chroot}": image_chroot_arg,
        "%{images}": " ".join([
          "--image_spec=%s" % spec
          for spec in image_specs
        ]),
        "%{resolver_args}": " ".join(ctx.attr.resolver_args or []),
      },
      output = ctx.outputs.executable,
  )

  return struct(runfiles = ctx.runfiles(files = [
    ctx.executable.resolver,
    ctx.file.template,
  ] + list(ctx.attr.resolver.default_runfiles.files) + all_inputs))

def resolve(ctx, string, output):
  stamps = [ctx.info_file, ctx.version_file]
  stamp_args = [
    "--stamp-info-file=%s" % sf.path
    for sf in stamps
  ]
  ctx.action(
    use_default_shell_env=True,
    executable = ctx.executable._stamper,
    arguments = [
      "--format=%s" % string,
      "--output=%s" % output.path,
    ] + stamp_args,
    inputs = [ctx.executable._stamper] + stamps,
    outputs = [output],
    mnemonic = "Stamp"
  )

def _common_impl(ctx):
  if ctx.attr.namespace and ctx.attr.namespace_file:
    fail("you should choose one: 'namespace' or 'namespace_file'")

  files = [ctx.executable.resolver]

  cluster_arg = ctx.attr.cluster
  cluster_arg = ctx.expand_make_variables("cluster", cluster_arg, {})
  if "{" in ctx.attr.cluster:
    cluster_file = ctx.new_file(ctx.label.name + ".cluster-name")
    resolve(ctx, ctx.attr.cluster, cluster_file)
    cluster_arg = "$(cat %s)" % _runfiles(ctx, cluster_file)
    files += [cluster_file]

  context_arg = ctx.attr.context
  context_arg = ctx.expand_make_variables("context", context_arg, {})
  if "{" in ctx.attr.context:
    context_file = ctx.new_file(ctx.label.name + ".context-name")
    resolve(ctx, ctx.attr.context, context_file)
    context_arg = "$(cat %s)" % _runfiles(ctx, context_file)
    files += [context_file]

  user_arg = ctx.attr.user
  user_arg = ctx.expand_make_variables("user", user_arg, {})
  if "{" in ctx.attr.user:
    user_file = ctx.new_file(ctx.label.name + ".user-name")
    resolve(ctx, ctx.attr.user, user_file)
    user_arg = "$(cat %s)" % _runfiles(ctx, user_file)
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
    namespace_arg = "$(cat %s)" % _runfiles(ctx, namespace_file)
    files += [namespace_file]

  if namespace_arg:
    namespace_arg = "--namespace=\"" +  namespace_arg + "\""

  substitutions = {
      "%{cluster}": cluster_arg,
      "%{context}": context_arg,
      "%{user}": user_arg,
      "%{namespace_arg}": namespace_arg,
      "%{kind}": ctx.attr.kind,
  }

  if hasattr(ctx.executable, "resolved"):
    substitutions["%{resolve_script}"] = _runfiles(ctx, ctx.executable.resolved)
    files += [ctx.executable.resolved]
    files += list(ctx.attr.resolved.default_runfiles.files)

  if hasattr(ctx.executable, "reversed"):
    substitutions["%{reverse_script}"] = _runfiles(ctx, ctx.executable.reversed)
    files += [ctx.executable.reversed]
    files += list(ctx.attr.reversed.default_runfiles.files)

  if hasattr(ctx.files, "unresolved"):
    substitutions["%{unresolved}"] = _runfiles(ctx, ctx.file.unresolved)
    files += ctx.files.unresolved

  ctx.actions.expand_template(
      template = ctx.file._template,
      substitutions = substitutions,
      output = ctx.outputs.executable,
  )
  return struct(runfiles = ctx.runfiles(files = files))

_common_attrs = {
    "before_command": attr.label(cfg = "host", executable=True),
    "before_command_args": attr.string_list(),
    "namespace": attr.string(),
    "namespace_file": attr.label(allow_single_file=True),
    # We allow cluster to be omitted, and we just
    # don't expose the extra actions.
    "cluster": attr.string(),
    "context": attr.string(),
    "user": attr.string(),
    # This is only needed for describe.
    "kind": attr.string(),
    "image_chroot": attr.string(),
    "resolver": attr.label(
        default = Label("//k8s:resolver"),
        cfg = "host",
        executable = True,
        allow_files = True,
    ),
    # Extra arguments to pass to the resolver.
    "resolver_args": attr.string_list(),
    "_stamper": attr.label(
        default = Label("//k8s:stamper"),
        cfg = "host",
        executable = True,
        allow_files = True,
    ),
}

def _reverse(ctx):
  """Implementation of _reversed."""
  ctx.actions.expand_template(
      template = ctx.file._template,
      substitutions = {
        "%{reverser}": _runfiles(ctx, ctx.executable.reverser),
        "%{yaml}": _runfiles(ctx, ctx.file.template),
      },
      output = ctx.outputs.executable,
  )

  return struct(runfiles = ctx.runfiles(files = [
    ctx.executable.reverser,
    ctx.file.template,
  ] + list(ctx.attr.reverser.default_runfiles.files)))

_reversed = rule(
    attrs = _add_dicts(
        {
            "template": attr.label(
                allow_files = [
                    ".yaml",
                    ".json",
                ],
                single_file = True,
                mandatory = True,
            ),
            "reverser": attr.label(
                default = Label("//k8s:reverser"),
                cfg = "host",
                executable = True,
                allow_files = True,
            ),
            "_template": attr.label(
                default = Label("//k8s:reverse.sh.tpl"),
                single_file = True,
                allow_files = True,
            ),
        },
        _common_attrs,
        _layer_tools,
    ),
    executable = True,
    implementation = _reverse,
)

_k8s_object = rule(
    attrs = _add_dicts(
        {
            "template": attr.label(
                allow_files = [
                    ".yaml",
                    ".json",
                ],
                single_file = True,
                mandatory = True,
            ),
            "images": attr.string_dict(),
            # Implicit dependencies.
            "image_targets": attr.label_list(allow_files = True),
            "image_target_strings": attr.string_list(),
            "_template": attr.label(
                default = Label("//k8s:resolve.sh.tpl"),
                single_file = True,
                allow_files = True,
            ),
        },
        _common_attrs,
        _layer_tools,
    ),
    executable = True,
    implementation = _impl,
)

_k8s_object_apply = rule(
    attrs = _add_dicts(
        {
            "resolved": attr.label(
                cfg = "target",
                executable = True,
                allow_files = True,
            ),
            "_template": attr.label(
                default = Label("//k8s:apply.sh.tpl"),
                single_file = True,
                allow_files = True,
            ),
        },
        _common_attrs,
    ),
    executable = True,
    implementation = _common_impl,
)

_k8s_object_create = rule(
    attrs = _add_dicts(
        {
            "resolved": attr.label(
                cfg = "target",
                executable = True,
                allow_files = True,
            ),
            "_template": attr.label(
                default = Label("//k8s:create.sh.tpl"),
                single_file = True,
                allow_files = True,
            ),
        },
        _common_attrs,
    ),
    executable = True,
    implementation = _common_impl,
)

_k8s_object_replace = rule(
    attrs = _add_dicts(
        {
            "resolved": attr.label(
                cfg = "target",
                executable = True,
                allow_files = True,
            ),
            "_template": attr.label(
                default = Label("//k8s:replace.sh.tpl"),
                single_file = True,
                allow_files = True,
            ),
        },
        _common_attrs,
    ),
    executable = True,
    implementation = _common_impl,
)

_k8s_object_describe = rule(
    attrs = _add_dicts(
        {
            "unresolved": attr.label(
                allow_files = [
                    ".yaml",
                    ".json",
                ],
                single_file = True,
                mandatory = True,
            ),
            "_template": attr.label(
                default = Label("//k8s:describe.sh.tpl"),
                single_file = True,
                allow_files = True,
            ),
        },
        _common_attrs,
    ),
    executable = True,
    implementation = _common_impl,
)

_k8s_object_delete = rule(
    attrs = _add_dicts(
        {
            "reversed": attr.label(
                cfg = "target",
                executable = True,
                allow_files = True,
            ),
            "_template": attr.label(
                default = Label("//k8s:delete.sh.tpl"),
                single_file = True,
                allow_files = True,
            ),
        },
        _common_attrs,
    ),
    executable = True,
    implementation = _common_impl,
)

def k8s_object(name, **kwargs):
  """Interact with a K8s object.
  Args:
    name: name of the rule.
    cluster: the name of the cluster.
    user: the user which has access to the cluster.
    namespace: the namespace within the cluster.
    kind: the object kind.
    template: the yaml template to instantiate.
    images: a dictionary from fully-qualified tag to label.
  """
  for reserved in ["image_targets", "image_target_strings", "resolved", "reversed"]:
    if reserved in kwargs:
      fail("reserved for internal use by docker_bundle macro", attr=reserved)

  kwargs["image_targets"] = _deduplicate(kwargs.get("images", {}).values())
  kwargs["image_target_strings"] = _deduplicate(kwargs.get("images", {}).values())

  _k8s_object(name=name, **kwargs)
  _reversed(name=name + ".reversed", template=kwargs.get("template"),
            visibility=kwargs.get("visibility"))

  if "cluster" in kwargs or "context" in kwargs:
    _k8s_object_create(
        name=name + ".create",
        resolved=name,
        kind=kwargs.get("kind"),
        cluster=kwargs.get("cluster"),
        context=kwargs.get("context"),
        user=kwargs.get("user"),
        namespace=kwargs.get("namespace"),
        namespace_file=kwargs.get("namespace_file"),
        before_command = kwargs.get("before_command"),
        visibility=kwargs.get("visibility"),
    )
    _k8s_object_delete(
        name=name + ".delete",
        reversed=name + ".reversed",
        kind=kwargs.get("kind"),
        cluster=kwargs.get("cluster"),
        context=kwargs.get("context"),
        user=kwargs.get("user"),
        namespace=kwargs.get("namespace"),
        namespace_file=kwargs.get("namespace_file"),
        before_command = kwargs.get("before_command"),
        visibility=kwargs.get("visibility"),
    )
    _k8s_object_replace(
        name=name + ".replace",
        resolved=name,
        kind=kwargs.get("kind"),
        cluster=kwargs.get("cluster"),
        context=kwargs.get("context"),
        user=kwargs.get("user"),
        namespace=kwargs.get("namespace"),
        namespace_file=kwargs.get("namespace_file"),
        before_command = kwargs.get("before_command"),
        visibility=kwargs.get("visibility"),
    )
    _k8s_object_apply(
        name=name + ".apply",
        resolved=name,
        kind=kwargs.get("kind"),
        cluster=kwargs.get("cluster"),
        context=kwargs.get("context"),
        user=kwargs.get("user"),
        namespace=kwargs.get("namespace"),
        namespace_file=kwargs.get("namespace_file"),
        before_command = kwargs.get("before_command"),
        visibility=kwargs.get("visibility"),
    )
    if "kind" in kwargs:
      _k8s_object_describe(
        name=name + ".describe",
        unresolved=kwargs.get("template"),
        kind=kwargs.get("kind"),
        cluster=kwargs.get("cluster"),
        context=kwargs.get("context"),
        user=kwargs.get("user"),
        namespace=kwargs.get("namespace"),
        namespace_file=kwargs.get("namespace_file"),
        before_command = kwargs.get("before_command"),
        visibility=kwargs.get("visibility"),
    )
