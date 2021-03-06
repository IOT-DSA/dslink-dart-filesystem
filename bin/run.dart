import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";
import "package:dslink/io.dart";
import "package:dslink/utils.dart";

import "dart:async";
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "package:path/path.dart" as pathlib;

import "package:watcher/watcher.dart";
import "package:watcher/src/resubscribable.dart";

LinkProvider link;
SimpleNodeProvider provider;
List<String> justRemovedPaths = [];

class ReferenceType {
  static const ReferenceType LIST = const ReferenceType("list");
  static const ReferenceType SUBSCRIBE = const ReferenceType("subscribe");
  static const ReferenceType MOUNT = const ReferenceType("mount");

  final String name;

  const ReferenceType(this.name);

  @override
  String toString() => name;
}

Directory currentDir;

main(List<String> args) async {
  link = new LinkProvider(args, "FileSystem-", provider: provider, autoInitialize: false, profiles: {
    "mount": (String path) => new MountNode(path),
    "addMount": (String path) => new AddMountNode(path),
    "remove": (String path) => new DeleteActionNode.forParent(path, provider, onDelete: () {
      link.save();
    }),
    "fileContent": (String path) => new FileContentNode(path),
    "fileModified": (String path) => new FileLastModifiedNode(path),
    "directoryMakeDirectory": (String path) => new DirectoryMakeDirectoryNode(path),
    "directoryMakeFile": (String path) => new DirectoryMakeFileNode(path),
    "fileDelete": (String path) => new FileDeleteNode(path),
    "fileLength": (String path) => new FileLengthNode(path),
    "fileMove": (String path) => new FileMoveNode(path),
    "readBinaryChunk": (String path) => new FileReadBinaryChunkNode(path),
    "publish": (String path) => new PublishFileNode(path)
  }, nodes: {
    "@dirty": true
  });

  link.configure(optionsHandler: (opts) {
    if (opts != null && opts["base-path"] != null) {
      currentDir = new Directory(opts["base-path"]);
    } else {
      currentDir = Directory.current;
    }
  });

  link.init();

  SimpleNode rootNode = link.provider.getNode("/");

  if (rootNode.attributes["@dirty"] == true) {
    var homeDir = pathlib.join(currentDir.path, "home");
    link.addNode("/default", {
      r"$is": "mount",
      r"$name": "default",
      "@directory": homeDir
    });
    rootNode.attributes.remove("@dirty");
  }

  provider = link.provider;

  String pathPlaceholder;

  if (Platform.isWindows) {
    pathPlaceholder = r"C:\Users\John Smith";
  } else if (Platform.isMacOS) {
    pathPlaceholder = "/Users/jsmith";
  } else {
    pathPlaceholder = "/home/jsmith";
  }

  link.addNode("/_@addMount", {
    r"$name": "Add Mount",
    r"$invokable": "write",
    r"$params": [
      {
        "name": "name",
        "type": "string"
      },
      {
        "name": "directory",
        "type": "string",
        "placeholder": pathPlaceholder
      },
      {
        "name": "showHiddenFiles",
        "type": "bool",
        "description": "Show Hidden Files"
      },
      {
        "name": "forceFilePolling",
        "type": "bool",
        "description": "Force File Polling"
      }
    ],
    r"$is": "addMount"
  });

  provider.registerResolver((String path) {
    List<String> parts = path.split("/");
    if (parts.length < 3) {
      return null;
    }

    String basePath = parts.take(2).join("/");

    if (provider.nodes[basePath] is! MountNode) {
      return null;
    }

    String name = parts.last;
    SimpleNode node;
    if (name == "_@content") {
      node = new FileContentNode(path);
    } else if (name == "_@modified") {
      node = new FileLastModifiedNode(path);
    } else if (name == "_@length") {
      node = new FileLengthNode(path);
    } else if (name == "_@mkdir") {
      node = new DirectoryMakeDirectoryNode(path);
    } else if (name == "_@mkfile") {
      node = new DirectoryMakeFileNode(path);
    } else if (name == "_@delete") {
      node = new FileDeleteNode(path);
    } else if (name == "_@move") {
      node = new FileMoveNode(path);
    } else if (name == "_@readBinaryChunk") {
      node = new FileReadBinaryChunkNode(path);
    } else if (name == ".") {
      node = null;
    } else {
      if (justRemovedPaths.contains(path)) {
        return null;
      }

      node = new FileSystemNode(path);
    }

    if (node != null) {
      provider.setNode(path, node);
      return node;
    } else {
      return null;
    }
  });

  await link.connect();

  Scheduler.safeEvery(Interval.SIXTEEN_MILLISECONDS, () async {
    while (writeQueue.isNotEmpty) {
      var item = writeQueue.removeAt(0);
      var file = new File(item.path);
      try {
        if (item.data is ByteData) {
          await file.writeAsBytes((item.data as ByteData).buffer.asUint8List());
        } else if (item.data == null) {
          await file.writeAsBytes([]);
        } else {
          await file.writeAsString(item.data.toString());
        }
      } catch (e) {
      }
    }
  });

  if (const bool.fromEnvironment("debugger", defaultValue: false)) {
    stdout.write("> ");
    readStdinLines().listen((line) {
      line = line.trim();
      if (line == "show-live-nodes") {
        print(provider.nodes.keys.map((n) => "- ${n}").join("\n"));
      } else if (line == "show-counts") {
        for (String key in provider.nodes.keys) {
          LocalNode node = provider.nodes[key];
          if (node is Collectable) {
            print("${key}: ${(node as Collectable)
                .calculateReferences()} references");
          }
        }
      } else if (line == "total-references") {
        int total = 0;
        for (LocalNode node in provider
            .getNode("/")
            .children
            .values) {
          if (node is Collectable) {
            total += (node as Collectable).calculateReferences();
          }
        }
        print("${total} total references");
      } else if (line == "trace-references") {
        for (String key in provider.nodes.keys) {
          LocalNode node = provider.nodes[key];
          if (node is ReferencedNode) {
            print("${node.path}: ${node.references.map((x) => x
              .toString()
              .split(".")
              .last).toList()}");
          }
        }
      } else if (line == "show-populate-queue") {
        print(FileSystemNode.POP_QUEUE);
      } else if (line == "node-types") {
        for (String key in provider.nodes.keys) {
          LocalNode node = provider.nodes[key];
          if (node is ReferencedNode) {
            print("${node.path}: ${node.runtimeType}");
          }
        }
      } else if (line == "help") {
        print(
          "Commands: show-live-nodes, node-types, show-counts"
          ", total-references, trace-references");
      } else if (line == "") {
      } else {
        print("Unknown Command: ${line}");
      }

      stdout.write("> ");
    });
  }
}

class AddMountNode extends SimpleNode {
  AddMountNode(String path) : super(path);

  @override
  onInvoke(Map<String, dynamic> params) async {
    var name = params["name"];
    var p = params["directory"];
    var showHiddenFiles = params["showHiddenFiles"];
    var usePollingOnly = params["forceFilePolling"];

    if (name == null) {
      throw new Exception("Name for mount was not provided.");
    }

    var tname = NodeNamer.createName(name);

    if (provider.nodes.containsKey("/${tname}")) {
      throw new Exception("Mount with name '${name}' already exists.");
    }

    if (p == null) {
      throw new Exception("Mount directory was not provided.");
    }

    var dir = new Directory(p).absolute;

    if (!(await dir.exists())) {
      await dir.create(recursive: true);
    }

    link.addNode("/${tname}", {
      r"$is": "mount",
      r"$name": name,
      "@directory": dir.path,
      "@showHiddenFiles": showHiddenFiles,
      "@filePollOnly": usePollingOnly
    });

    link.save();
  }
}

class MountNode extends FileSystemNode {
  int get maxContentSize => 64 * 1024 * 1024;
  String get directory => attributes["@directory"];
  bool get isPollOnly => attributes["@filePollOnly"] == true;
  bool get showHiddenFiles => attributes["@showHiddenFiles"] == true;

  MountNode(String path) : super(path) {
    references.add(ReferenceType.MOUNT);
  }

  @override
  onCreated() {
    link.addNode("${path}/_@unmount", {
      r"$name": "Unmount",
      r"$is": "remove",
      r"$invokable": "write"
    });

    link.addNode("${path}/_@publish", {
      r"$name": "Publish File",
      r"$is": "publish",
      r"$invokable": "write",
      r"$params": [
        {
          "name": "File",
          "type": "string",
          "placeholder": "myfile.txt"
        },
        {
          "name": "Content",
          "type": "string",
          "editor": "textarea"
        }
      ]
    });

    new Future(() async {
      try {
        var dir = new Directory(directory);
        if (!(await dir.exists())) {
          await dir.create(recursive: true);
        }
      } catch (e) {}
    });
  }

  String resolveChildFilePath(String childPath) {
    var relative = childPath.split("/").skip(2).map(NodeNamer.decodeName).join("/");
    return pathlib.join(directory, relative);
  }

  @override
  void collect() { // Don't collect the mount nodes.
    var refs = calculateReferences();
    if (refs == 0) {
      collectChildren();
      findStrayNodesAndCollect();
    }
  }

  void findStrayNodesAndCollect() {
    String base = path + "/";
    for (String key in provider.nodes.keys.toList()) {
      if (key.startsWith(base) &&
        !key.endsWith("/_@unmount") &&
        !key.endsWith("/_@publish")) {
        provider.removeNode(key);
      }
    }
  }

  @override
  Map save() {
    return {
      r"$is": "mount",
      r"$name": configs[r"$name"],
      "@directory": attributes["@directory"],
      "@showHiddenFiles": attributes["@showHiddenFiles"],
      "@filePollOnly": attributes["@filePollOnly"]
    };
  }

  @override
  onRemoving() {
    super.onRemoving();
    findStrayNodesAndCollect();
  }
}

abstract class Collectable {
  void collect();
  void collectChildren();
  int calculateReferences([bool includeChildren = true]);
}

abstract class ValueExpendable {
  loadValue();
}

abstract class ReferencedNode extends SimpleNode implements Collectable {
  ReferencedNode(String path) : super(path);

  @override
  int calculateReferences([bool includeChildren = true]) {
    int total = references.length;

    if (includeChildren) {
      for (LocalNode node in children.values) {
        if (node is Collectable) {
          total += (node as Collectable).calculateReferences();
        }
      }
    }

    return total;
  }

  @override
  void collect() {
    int allReferenceCounts = parent is Collectable ?
      (parent as Collectable).calculateReferences(false) :
      calculateReferences();

    if (allReferenceCounts == 0) {
      remove();
    }
  }

  @override
  void collectChildren() {
  }

  @override
  onStartListListen() {
    references.add(ReferenceType.LIST);
  }

  @override
  onAllListCancel() {
    references.removeWhere((x) => x == ReferenceType.LIST);
    collect();
  }

  @override
  onSubscribe() {
    if (!references.contains(ReferenceType.SUBSCRIBE) && this is ValueExpendable) {
      (this as ValueExpendable).loadValue();
    }

    references.add(ReferenceType.SUBSCRIBE);
  }

  @override
  onUnsubscribe() {
    references.remove(ReferenceType.SUBSCRIBE);
    collect();

    if (!references.contains(ReferenceType.SUBSCRIBE)) {
      clearValue();
    }
  }

  List<ReferenceType> references = [];
}

class FileSystemNode extends ReferencedNode implements WaitForMe {
  static List<String> POP_QUEUE = [];

  Path p;
  MountNode mount;
  String filePath;
  FileSystemEntity entity;
  DirectoryWatcher dirwatch;

  FileSystemNode(String path) : super(path) {
    p = new Path(path);
    attributes["@file"] = true;
  }

  List<Function> _onPopulated = [];
  bool _isPopulating = false;

  Future populate() {
    if (isPopulated) {
      return new Future.value();
    }

    logger.fine("Populating ${path}");

    if (_isPopulating) {
      logger.fine("Waiting for existing population task on ${path}");

      var c = new Completer();
      _onPopulated.add(() {
        c.complete();
      });

      return c.future.timeout(const Duration(seconds: 3), onTimeout: () {
        _isPopulating = false;
        logger.fine("Waiting timed out for ${path}, retrying a populate.");
        return populate();
      });
    }

    _isPopulating = true;
    if (!POP_QUEUE.contains(path)) {
      POP_QUEUE.add(path);
    }

    void done() {
      _isPopulating = false;
      POP_QUEUE.remove(path);

      while (_onPopulated.isNotEmpty) {
        _onPopulated.removeAt(0)();
      }

      logger.fine("${path} is now populated");
    }

    return new Future(() async {
      var mountPath = path.split("/").take(2).join("/");

      mount = link.getNode(mountPath);

      if (mount is! MountNode) {
        done();
        throw new Exception("Mount not found.");
      }

      filePath = mount.resolveChildFilePath(path);

      entity = await getFileSystemEntity(filePath);

      if (entity == null) {
        remove();
        done();
        return;
      }

      // Entity does not exist. Mark us as not populated to re-verify.
      if (!(await entity.exists())) {
        isPopulated = false;
        done();
        remove();
        return;
      }

      Map<String, Map> childQueue = {};

      try {
        if (entity is Directory) {
          await for (FileSystemEntity child in (entity as Directory).list()) {
            String relative = pathlib.relative(child.path, from: entity.path);
            if (relative.startsWith(".") && !mount.showHiddenFiles) {
              continue;
            }
            String name = NodeNamer.createName(relative);
            FileSystemNode node = new FileSystemNode("${path}/${name}");
            if (!provider.hasNode(node.path)) {
              node.populate();
            }
          }

          if (fileWatchSub != null) {
            fileWatchSub.cancel();
          }

          try {
            if (!Platform.isMacOS) {
              dirwatch = mount.isPollOnly
                ? new PollingDirectoryWatcher(entity.path)
                : new DirectoryWatcher(entity.path);
              dirwatch.events.listen((WatchEvent event) async {
                if (event.path == filePath || event.path == ".") {
                  if (event.type == ChangeType.REMOVE) {
                    remove();
                    addToJustRemovedQueue(path);
                    parent.updateList(new Path(path).name);
                    updateList(r"$is");
                    return;
                  }

                  if (event.path == ".") {
                    return;
                  }
                }

                if (!pathlib.isAbsolute(event.path) && event.path.contains("/")) {
                  return;
                }

                if (event.type == ChangeType.ADD) {
                  FileSystemEntity child = await getFileSystemEntity(
                    pathlib.join(entity.path, event.path)
                  );

                  if (child != null) {
                    child = child.absolute;
                    String relative = pathlib.relative(child.path, from: entity.path);
                    if (relative.startsWith(".") && !mount.showHiddenFiles) {
                      return;
                    }

                    String base = pathlib.dirname(relative);

                    String name = (base == "." ? "" : "${base}/") +
                      "${NodeNamer.createName(pathlib.basename(relative))}";

                    FileSystemNode node = new FileSystemNode("${path}/${name}");
                    node.populate();
                  }
                } else if (event.type == ChangeType.REMOVE) {
                  String relative = pathlib.normalize(
                    pathlib.relative(
                      pathlib.join(entity.path, event.path),
                      from: entity.path
                    )
                  );

                  String base = pathlib.dirname(relative);
                  String name = (base == "." ? "" : "${base}/") +
                    "${NodeNamer.createName(pathlib.basename(relative))}";

                  provider.removeNode("${path}/${name}");
                  addToJustRemovedQueue("${path}/${name}");
                  updateList(name);
                }
              }, onError: (e, stack) {
                logger.warning("Failed to watch ${filePath}.", e, stack);
              });
            } else {
              fileWatchSub = entity.watch().listen((FileSystemEvent event) async {
                if (event.path == filePath || event.path == ".") {
                  if (event.type == FileSystemEvent.DELETE) {
                    remove();
                    addToJustRemovedQueue(path);
                    parent.updateList(new Path(path).name);
                    updateList(r"$is");
                    return;
                  }

                  if (event.path == ".") {
                    return;
                  }
                }

                if (!pathlib.isAbsolute(event.path) && event.path.contains("/")) {
                  return;
                }

                if (event.type == FileSystemEvent.CREATE) {
                  FileSystemEntity child = await getFileSystemEntity(
                    pathlib.join(entity.path, event.path)
                  );

                  if (child != null) {
                    child = child.absolute;
                    String relative = pathlib.relative(child.path, from: entity.path);
                    if (relative.startsWith(".") && !mount.showHiddenFiles) {
                      return;
                    }

                    String base = pathlib.dirname(relative);

                    String name = (base == "." ? "" : "${base}/") +
                      "${NodeNamer.createName(pathlib.basename(relative))}";

                    FileSystemNode node = new FileSystemNode("${path}/${name}");
                    node.populate();
                  }
                } else if (event.type == FileSystemEvent.DELETE) {
                  String relative = pathlib.normalize(
                    pathlib.relative(
                      pathlib.join(entity.path, event.path),
                      from: entity.path
                    )
                  );

                  String base = pathlib.dirname(relative);
                  String name = (base == "." ? "" : "${base}/") +
                    "${NodeNamer.createName(pathlib.basename(relative))}";

                  provider.removeNode("${path}/${name}");
                  addToJustRemovedQueue("${path}/${name}");
                  updateList(name);
                }
              }, onError: (e, stack) {
                logger.warning("Failed to watch ${filePath}.", e, stack);
              });
            }

            fileWatchSub.onDone(() {
              if (dirwatch is ManuallyClosedWatcher) {
                (dirwatch as ManuallyClosedWatcher).close();
              }
            });
          } catch (e) {
          }

          childQueue["_@mkdir"] = {
            r"$is": "directoryMakeDirectory"
          };

          childQueue["_@mkfile"] = {
            r"$is": "directoryMakeFile"
          };
        } else if (entity is File) {
          var watcher = mount.isPollOnly
            ? new PollingFileWatcher(entity.path)
            : new FileWatcher(entity.path);
          fileWatchSub = watcher.events.listen((WatchEvent event) async {
            if (event.type == ChangeType.MODIFY) {
              FileContentNode contentNode = children["_@content"];
              if (contentNode != null && contentNode.hasSubscriber) {
                await contentNode.loadValue();
              }

              FileLastModifiedNode modifiedNode = children["_@modified"];
              if (modifiedNode != null && modifiedNode.hasSubscriber) {
                await modifiedNode.loadValue();
              }

              FileLengthNode lengthNode = children["_@length"];
              if (lengthNode != null) {
                await lengthNode.loadValue();
              }
            }
          }, onError: (e, stack) {
            logger.warning("Failed to watch ${filePath}.", e, stack);
          });

          fileWatchSub.onDone(() {
            if (watcher is ManuallyClosedWatcher) {
              (watcher as ManuallyClosedWatcher).close();
            }
          });

          childQueue["_@content"] = {
            r"$is": "fileContent",
            r"$name": "Content",
            r"$type": "string"
          };

          childQueue["_@readBinaryChunk"] = {
            r"$is": "readBinaryChunk",
            r"$invokable": "read"
          };

          childQueue["_@length"] = {
            r"$is": "fileLength",
            r"$name": "Size",
            r"$type": "string"
          };

          childQueue["_@modified"] = {
            r"$is": "fileModified",
            r"$name": "Last Modified",
            r"$type": "string"
          };
        }

        childQueue["_@delete"] = {
          r"$is": "fileDelete",
          r"$invokable": "write",
          r"$params": [
            {
              "name": "areYouSure",
              "type": "bool",
              "default": false
            }
          ]
        };

        childQueue["_@move"] =  {
          r"$is": "fileMove",
          r"$invokable": "write",
          r"$params": [
            {
              "name": "target",
              "type": "string",
              "placeholder": "file.txt"
            }
          ]
        };
      } catch (e) {
        var err = e;
        if (!children.containsKey("_@error")) {
          link.addNode("${path}/_@error", {
            r"$name": "Error",
            r"$type": "string"
          });
        }

        if (err is FileSystemException) {
          err = err.message + " (path: ${err.path})${err.osError != null ? ' (OS error: ${err.osError})' : ''}";
        }

        if (children["_@error"] != null) {
          (children["_@error"] as SimpleNode).updateValue(err.toString());
        }
      }

      if (!provider.hasNode(path)) {
        provider.setNode(path, this);
      }

      for (String key in childQueue.keys) {
        String childPath = "${path}/${key}";
        if (link.getNode(childPath) == null) {
          link.addNode("${path}/${key}", childQueue[key]);
        }
      }

      childQueue.clear();

      done();
      isPopulated = true;
    });
  }

  bool isPopulated = false;
  StreamSubscription fileWatchSub;

  @override
  Future get onLoaded {
    if (isPopulated) {
      return new Future.sync(() => this);
    }
    return populate();
  }

  @override
  void collect() {
    if (const bool.fromEnvironment("verbose.collect", defaultValue: false)) {
      print("[Node Collector] collect() called on ${path}");
    }

    LocalNode parent = provider.getNode(p.parentPath);

    int allReferenceCounts = parent is Collectable ?
      (parent as Collectable).calculateReferences(false) :
      calculateReferences();

    if (allReferenceCounts == 0) {
      if (const bool.fromEnvironment("verbose.collect", defaultValue: false)) {
        print("[Node Collector] Collecting ${path}");
      }

      collectChildren();
      parent.removeChild(p.name);
      parent.listChangeController.add(p.name);
      isPopulated = false;
      return;
    }
  }

  @override
  void collectChildren() {
    for (SimpleNode node in children.values.toList()) {
      if (node is Collectable) {
        (node as Collectable).collect();
      }
    }
  }

  @override
  onRemoving() {
    super.onRemoving();
    _isPopulating = false;
    if (fileWatchSub != null) {
      fileWatchSub.cancel();
    }
  }
}

class FileLastModifiedNode extends ReferencedNode implements WaitForMe, ValueExpendable {
  FileSystemNode fileNode;

  FileLastModifiedNode(String path) : super(path) {
    configs[r"$type"] = "string";
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  loadValue() async {
    if (isLoadingValue) {
      await new Future.delayed(const Duration(milliseconds: 25), loadValue);
      return;
    }

    isLoadingValue = true;

    try {
      updateValue((await (fileNode.entity as File).lastModified()).toString());
    } catch (e) {
    }
    isLoadingValue = false;
  }

  bool isLoadingValue = false;

  @override
  onRemoving() {
    super.onRemoving();
    clearValue();
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class FileLengthNode extends ReferencedNode implements WaitForMe, ValueExpendable {
  FileSystemNode fileNode;

  FileLengthNode(String path) : super(path) {
    configs[r"$type"] = "number";
    attributes["@unit"] = "bytes";
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }

    updateList("@unit");
  }

  loadValue() async {
    if (isLoadingValue) {
      await new Future.delayed(const Duration(milliseconds: 25), loadValue);
      return;
    }

    isLoadingValue = true;

    try {
      updateValue(await (fileNode.entity as File).length());
    } catch (e) {
    }
    isLoadingValue = false;
  }

  bool isLoadingValue = false;

  @override
  onRemoving() {
    super.onRemoving();
    clearValue();
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class FileWriteQueue {
  final String path;
  final dynamic data;

  FileWriteQueue(this.path, this.data);
}

List<FileWriteQueue> writeQueue = [];

class FileContentNode extends ReferencedNode implements WaitForMe, ValueExpendable {
  FileSystemNode fileNode;
  MountNode mount;

  FileContentNode(String path) : super(path) {
    configs[r"$writable"] = "write";
    configs[r"$type"] = "string";
    configs[r"$editor"] = "textarea";
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }

    var mountPath = path.split("/").take(2).join("/");

    mount = link.getNode(mountPath);
  }

  @override
  onSetValue(Object val) {
    String p = fileNode.filePath;
    writeQueue.removeWhere((x) => x.path == p);
    writeQueue.add(new FileWriteQueue(p, val));
    return true;
  }

  loadValue() async {
    if (isLoadingValue) {
      await new Future.delayed(const Duration(milliseconds: 25), loadValue);
      return;
    }

    isLoadingValue = true;

    try {
      var file = fileNode.entity as File;
      var len = await file.length();
      if (len < (mount.maxContentSize)) {
        Uint8List bytes = await file.readAsBytes();
        var oldType = configs[r"$type"];
        try {
          configs[r"$type"] = "string";
          configs[r"$editor"] = "textarea";
          updateValue(const Utf8Decoder().convert(bytes));
        } catch (e) {
          configs[r"$type"] = "binary";
          configs.remove(r"$editor");
          updateValue(bytes.buffer.asByteData());
        }
        var newType = configs[r"$type"];
        if (oldType != newType) {
          updateList(r"$type");
        }
      } else {
        updateValue(null);
      }
    } catch (e) {
    }
    isLoadingValue = false;
  }

  bool isLoadingValue = false;

  @override
  onRemoving() {
    super.onRemoving();
    clearValue();
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class DirectoryMakeFileNode extends ReferencedNode implements WaitForMe {
  FileSystemNode fileNode;

  DirectoryMakeFileNode(String path) : super(path) {
    configs[r"$name"] = "Create File";
    configs[r"$invokable"] = "write";
    configs[r"$params"] = [
      {
        "name": "name",
        "type": "string",
        "placeholder": "file.txt"
      }
    ];
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  @override
  onInvoke(Map<String, dynamic> params) async {
    String name = params["name"];
    if (name == null || name.isEmpty) {
      throw new Exception("File name not provided.");
    }

    Directory entity = fileNode.entity;
    File created = new File(pathlib.join(entity.path, name));

    if (await created.exists()) {
      throw new Exception("File '${name}' already exists.");
    }

    await created.create(recursive: true);
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class DirectoryMakeDirectoryNode extends ReferencedNode implements WaitForMe {
  FileSystemNode fileNode;

  DirectoryMakeDirectoryNode(String path) : super(path) {
    configs[r"$name"] = "Create Directory";
    configs[r"$invokable"] = "write";
    configs[r"$params"] = [
      {
        "name": "name",
        "type": "string",
        "placeholder": "MyDir"
      }
    ];
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  @override
  onInvoke(Map<String, dynamic> params) async {
    String name = params["name"];
    if (name == null || name.isEmpty) {
      throw new Exception("Directory name not provided.");
    }

    Directory entity = fileNode.entity;
    Directory created = new Directory(pathlib.join(entity.path, name));

    if (await created.exists()) {
      throw new Exception("Directory '${name}' already exists.");
    }

    await created.create(recursive: true);
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class FileDeleteNode extends ReferencedNode implements WaitForMe {
  FileSystemNode fileNode;

  FileDeleteNode(String path) : super(path) {
    configs[r"$name"] = "Delete";
    configs[r"$invokable"] = "write";
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  @override
  onInvoke(Map<String, dynamic> params) async {
    if (params["areYouSure"] == false) {
      return;
    }

    try {
      await fileNode.entity.delete(recursive: true);
      fileNode.remove();
      addToJustRemovedQueue(fileNode.path);
    } catch (e) {}
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class FileReadBinaryChunkNode extends ReferencedNode implements WaitForMe {
  FileSystemNode fileNode;

  FileReadBinaryChunkNode(String path) : super(path) {
    configs[r"$name"] = "Read Binary Chunk";
    configs.addAll({
      r"$params": [
        {
          "name": "start",
          "type": "int",
          "default": 0
        },
        {
          "name": "end",
          "type": "int"
        }
      ],
      r"$result": "values",
      r"$invokable": "read",
      r"$columns": [
        {
          "name": "data",
          "type": "binary"
        }
      ]
    });
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  @override
  onInvoke(Map<String, dynamic> params) async {
    int start = int.parse(params["start"].toString(), onError: (s) => null);
    int end = int.parse(params["end"].toString(), onError: (s) => null);

    if (start == null || start < 0) {
      start = 0;
    }

    var file = fileNode.entity;
    if (end == null || end < 0) {
      end = await file.length();
    }

    Uint8List data = await file.openRead(start, end).reduce((Uint8List a, Uint8List b) {
      var list = new Uint8List(a.length + b.length);
      var c = 0;
      for (var byte in a) {
        list[c] = byte;
        c++;
      }

      for (var byte in b) {
        list[c] = byte;
        c++;
      }
      return list;
    });

    return {
      "data": data.buffer.asByteData()
    };
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class FileMoveNode extends ReferencedNode implements WaitForMe {
  FileSystemNode fileNode;

  FileMoveNode(String path) : super(path) {
    configs[r"$name"] = "Move";
    configs[r"$invokable"] = "write";
    configs[r"$params"] = [
      {
        "name": "target",
        "type": "string",
        "placeholder": "file.txt"
      }
    ];
  }

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  @override
  onInvoke(Map<String, dynamic> params) async {
    await fileNode.entity.rename(pathlib.join(
      fileNode.entity.parent.path,
      params["target"]
    ));
  }

  @override
  Future get onLoaded {
    if (!fileNode.isPopulated) {
      return fileNode.populate();
    } else {
      return new Future.value();
    }
  }
}

class PublishFileNode extends SimpleNode {
  PublishFileNode(String path) : super(path);

  @override
  onInvoke(Map<String, dynamic> params) async {
    var path = params["File"];
    var content = params["Content"];

    if (path is! String) {
      throw new Exception("File path not specified.");
    }

    MountNode mount = parent;

    path = pathlib.join(mount.filePath, path);

    File file = new File(path).absolute;
    if (!(await file.exists())) {
      await file.create(recursive: true);
    }

    if (content is ByteData) {
      await file.writeAsBytes(content.buffer.asUint8List());
    } else {
      await file.writeAsString(content.toString());
    }

    if (pathlib.isWithin(mount.filePath, file.path)) {
      String mpart = pathlib.posix.normalize(
        pathlib.relative(file.path, from: mount.filePath)
      );

      String base = pathlib.dirname(mpart);

      String name = (base == "." ? "" : "${base}/") +
        "${NodeNamer.createName(pathlib.basename(mpart))}";

      String fp = "${mount.path}/";

      if (base != ".") {
        fp += "${base}/";
      }

      fp += name;
      FileSystemNode node = new FileSystemNode(fp);
      await node.populate();
    }
  }
}

Map<FileSystemEntityType, String> FS_TYPE_NAMES = {
  FileSystemEntityType.DIRECTORY: "directory",
  FileSystemEntityType.FILE: "file"
};

Future<FileSystemEntity> getFileSystemEntity(String path) async {
  var type = await FileSystemEntity.type(path);
  if (type == FileSystemEntityType.FILE) {
    return new File(path).absolute;
  } else if (type == FileSystemEntityType.DIRECTORY) {
    return new Directory(path).absolute;
  } else {
    return null;
  }
}

addToJustRemovedQueue(String p) {
  justRemovedPaths.add(p);

  new Future.delayed(const Duration(seconds: 2), () async {
    justRemovedPaths.remove(p);
  });
}
