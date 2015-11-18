import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";
import "package:dslink/io.dart";

import "dart:async";
import "dart:io";

import "package:path/path.dart" as pathlib;

LinkProvider link;
SimpleNodeProvider provider;

main(List<String> args) async {
  link = new LinkProvider(args, "FileSystem-", nodes: {
    "home": {
      r"$is": "mount",
      "@directory": "/Users/alex"
    }
  }, profiles: {
    "mount": (String path) => new MountNode(path)
  }, autoInitialize: false);

  link.init();
  await link.connect();

  provider = link.provider;

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

class MountNode extends FileSystemNode {
  String get directory => attributes["@directory"];

  MountNode(String path) : super(path);

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

    FileSystemEntity entity = await getFileSystemEntity(filePath);

    if (entity == null) {
      remove();
      return;
    }

    // Entity does not exist. Mark us as not populated to re-verify.
    if (!(await entity.exists())) {
      return;
    }

    if (entity is Directory) {
      await for (FileSystemEntity child in entity.list()) {
        String relative = pathlib.relative(child.path, from: entity.path);
        String name = NodeNamer.createName(relative);
        FileSystemNode node = new FileSystemNode("${path}/${name}");
        provider.setNode(node.path, node);
      }

      if (directoryWatchSub != null) {
        directoryWatchSub.cancel();
      }

      directoryWatchSub = entity.watch().listen((FileSystemEvent event) async {
        if (event.path == filePath) {
          if (event.type == FileSystemEvent.DELETE) {
            remove();
            return;
          }
        }

        if (event.type == FileSystemEvent.CREATE) {
          FileSystemEntity child = await getFileSystemEntity(event.path);
          String relative = pathlib.relative(child.path, from: entity.path);
          String name = NodeNamer.createName(relative);
          FileSystemNode node = new FileSystemNode("${path}/${name}");
          provider.setNode(node.path, node);
        } else if (event.type == FileSystemEvent.DELETE) {
          String relative = pathlib.relative(event.path, from: entity.path);
          String name = NodeNamer.createName(relative);
          provider.removeNode("${path}/${name}");
        }
      });
    }

    isPopulated = true;
  }

  bool isPopulated = false;
  StreamSubscription directoryWatchSub;

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
