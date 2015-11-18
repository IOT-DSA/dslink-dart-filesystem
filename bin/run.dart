import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";
import "package:dslink/io.dart";

import "dart:async";
import "dart:io";

import "package:path/path.dart" as pathlib;

LinkProvider link;
SimpleNodeProvider provider;

main(List<String> args) async {
  link = new LinkProvider(args, "FileSystem-", provider: provider, autoInitialize: false, profiles: {
    "mount": (String path) => new MountNode(path),
    "addMount": (String path) => new AddMountNode(path),
    "remove": (String path) => new DeleteActionNode.forParent(path, provider, onDelete: () {
      link.save();
    }),
    "fileContent": (String path) => new FileContentNode(path),
    "fileModified": (String path) => new FileLastModifiedNode(path)
  });

  link.init();

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
    if (name == "_@content") {
      var node = new FileContentNode(path);
      provider.setNode(path, node);
      return node;
    } else if (name == "_@modified") {
      var node = new FileContentNode(path);
      provider.setNode(path, node);
      return node;
    } else {
      var node = new FileSystemNode(path);
      provider.setNode(path, node);
      return node;
    }
  });

  await link.connect();

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
        for (LocalNode node in provider.getNode("/").children.values) {
          if (node is Collectable) {
            total += (node as Collectable).calculateReferences();
          }
        }
        print("${total} total references");
      } else if (line == "help") {
        print("Commands: show-live-nodes, show-counts, total-references");
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
      "@directory": dir.path
    });

    link.save();
  }
}

class MountNode extends FileSystemNode {
  String get directory => attributes["@directory"];

  MountNode(String path) : super(path);

  @override
  onCreated() {
    super.onCreated();

    link.addNode("${path}/_@unmount", {
      r"$name": "Unmount",
      r"$is": "remove",
      r"$invokable": "write"
    });
  }

  String resolveChildFilePath(String childPath) {
    var relative = childPath.split("/").skip(2).map(NodeNamer.decodeName).join("/");
    return pathlib.join(directory, relative);
  }

  @override
  void doNodeCollection() { // Don't collect the mount nodes.
    collectChildren();
    findStrayNodesAndCollect();
  }

  void findStrayNodesAndCollect() {
    String base = path + "/";
    for (String key in provider.nodes.keys.toList()) {
      if (key.startsWith(base)) {
        provider.removeNode(key);
      }
    }
  }

  @override
  Map save() {
    return {
      r"$is": "mount",
      r"$name": configs[r"$name"],
      "@directory": attributes["@directory"]
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

class FileSystemNode extends SimpleNode implements WaitForMe, Collectable {
  Path p;
  MountNode mount;
  String filePath;
  FileSystemEntity entity;

  FileSystemNode(String path) : super(path) {
    p = new Path(path);
  }

  populate() async {
    if (isPopulated) {
      return;
    }

    var mountPath = path.split("/").take(2).join("/");

    mount = link.getNode(mountPath);

    if (mount is! MountNode) {
      throw new Exception("Mount not found.");
    }

    filePath = mount.resolveChildFilePath(path);

    entity = await getFileSystemEntity(filePath);

    if (entity == null) {
      remove();
      return;
    }

    // Entity does not exist. Mark us as not populated to re-verify.
    if (!(await entity.exists())) {
      return;
    }

    try {
      if (entity is Directory) {
        await for (FileSystemEntity child in (entity as Directory).list()) {
          String relative = pathlib.relative(child.path, from: entity.path);
          String name = NodeNamer.createName(relative);
          FileSystemNode node = new FileSystemNode("${path}/${name}");
          provider.setNode(node.path, node);
        }

        if (fileWatchSub != null) {
          fileWatchSub.cancel();
        }

        fileWatchSub = entity.watch().listen((FileSystemEvent event) async {
          if (event.path == filePath) {
            if (event.type == FileSystemEvent.DELETE) {
              remove();
              return;
            }
          }

          if (event.type == FileSystemEvent.CREATE) {
            FileSystemEntity child = await getFileSystemEntity(event.path);
            if (child != null) {
              String relative = pathlib.relative(child.path, from: entity.path);
              String name = NodeNamer.createName(relative);
              FileSystemNode node = new FileSystemNode("${path}/${name}");
              provider.setNode(node.path, node);
            }
          } else if (event.type == FileSystemEvent.DELETE) {
            String relative = pathlib.relative(event.path, from: entity.path);
            String name = NodeNamer.createName(relative);
            provider.removeNode("${path}/${name}");
          }
        });
      } else if (entity is File) {
        fileWatchSub = entity.watch().listen((FileSystemEvent event) async {
          if (event.type == FileSystemEvent.DELETE) {
            remove();
            return;
          } else if (event.type == FileSystemEvent.MODIFY) {
            await (children["_@content"] as FileContentNode).loadValue();
            await (children["_@modified"] as FileLastModifiedNode).loadValue();
          }
        });

        link.addNode("${path}/_@content", {
          r"$is": "fileContent",
          r"$name": "Content",
          r"$type": "string"
        });

        link.addNode("${path}/_@modified", {
          r"$is": "fileModified",
          r"$name": "Last Modified",
          r"$type": "string"
        });
      }
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

      (children["_@error"] as SimpleNode).updateValue(err.toString());
    }

    isPopulated = true;
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
  int calculateReferences([bool includeChildren = true]) {
    int total = referenceCount;

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
      remove();
      return;
    }
  }

  void doNodeCollection() {
    collect();
  }

  int referenceCount = 0;

  @override
  onStartListListen() {
    referenceCount++;
  }

  @override
  onAllListCancel() {
    referenceCount--;
    doNodeCollection();
  }

  @override
  onSubscribe() {
    referenceCount++;
  }

  @override
  onUnsubscribe() {
    referenceCount--;
    doNodeCollection();
  }

  @override
  void collectChildren() {
    for (LocalNode node in children.values.toList()) {
      if (node is Collectable) {
        (node as Collectable).collect();
      }
    }
    isPopulated = false;
  }

  @override
  onRemoving() {
    super.onRemoving();
    if (fileWatchSub != null) {
      fileWatchSub.cancel();
    }
  }
}

class FileLastModifiedNode extends SimpleNode implements Collectable, WaitForMe {
  FileSystemNode fileNode;

  FileLastModifiedNode(String path) : super(path);

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  @override
  int calculateReferences([bool includeChildren = true]) {
    return referenceCount;
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
  onSubscribe() {
    super.onSubscribe();
    referenceCount++;
    loadValue();
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
  onUnsubscribe() {
    referenceCount--;
    collect();
  }

  int referenceCount = 0;

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

class FileContentNode extends SimpleNode implements Collectable, WaitForMe {
  FileSystemNode fileNode;

  FileContentNode(String path) : super(path);

  @override
  onCreated() {
    fileNode = link.getNode(new Path(path).parentPath);

    if (fileNode is! FileSystemNode) {
      remove();
      return;
    }
  }

  @override
  int calculateReferences([bool includeChildren = true]) {
    return referenceCount;
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
  onSubscribe() {
    super.onSubscribe();
    referenceCount++;
    loadValue();
  }

  loadValue() async {
    if (isLoadingValue) {
      await new Future.delayed(const Duration(milliseconds: 25), loadValue);
      return;
    }

    isLoadingValue = true;

    try {
      updateValue(await (fileNode.entity as File).readAsString());
    } catch (e) {
    }
    isLoadingValue = false;
  }

  bool isLoadingValue = false;

  @override
  onUnsubscribe() {
    referenceCount--;
    collect();
  }

  int referenceCount = 0;

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

Map<FileSystemEntityType, String> FS_TYPE_NAMES = {
  FileSystemEntityType.DIRECTORY: "directory",
  FileSystemEntityType.FILE: "file"
};

Future<FileSystemEntity> getFileSystemEntity(String path) async {
  var type = await FileSystemEntity.type(path);
  if (type == FileSystemEntityType.FILE) {
    return new File(path);
  } else if (type == FileSystemEntityType.DIRECTORY) {
    return new Directory(path);
  } else {
    return null;
  }
}
