import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";

import "dart:async";
import "dart:io";

import "package:path/path.dart" as pathlib;

LinkProvider link;
ResolvingNodeProvider provider;

addMountFunction(Map<String, dynamic> params) async {
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

  var n = provider.nodes["/${tname}"] = new SimpleNode("/${tname}");

  n.configs[r"$name"] = name;
  n.attributes["@directory"] = dir.path;
  provider.nodes["/"].addChild(tname, n);

  link.save();
}

main(List<String> args) async {
  provider = new CustomResolvingNodeProvider();
  link = new LinkProvider(args, "FileSystem-", provider: provider, autoInitialize: false, profiles: {
    "addMount": (String path) => new SimpleActionNode(path, (Map<String, dynamic> params) async {
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

      var n = provider.nodes["/${tname}"] = new SimpleNode("/${tname}");

      n.configs[r"$name"] = name;
      n.attributes["@directory"] = dir.path;

      link.save();
    })
  });

  provider.handler = (CallbackNode node) async {
    List<String> parts = node.path.split("/").map(NodeNamer.decodeName).toList();

    String filePath;

    String mountPath = "/${parts[1]}";
    SimpleNode mount = provider.nodes.containsKey(mountPath) ? provider.nodes[mountPath] : null;

    if (mount != null && mount.attributes["@directory"] is! String) {
      mount = null;
    }

    if (mount != null) {
      filePath = pathlib.join(mount.attributes["@directory"], parts.skip(2).join("/"));
    } else {
      return false;
    }

    var stat = await FileStat.stat(filePath);
    if (stat.type == FileSystemEntityType.NOT_FOUND) {
      return false;
    }

    if (parts.last.startsWith("_@")) {
      var c = new Completer.sync();
      (link.provider as ResolvingNodeProvider).getNode(parts.take(parts.length - 1).join("/"), onLoaded: c);
      await c.future;
    }

    node.attributes["@fileType"] = FS_TYPE_NAMES[stat.type];

    if (stat.type == FileSystemEntityType.DIRECTORY) {
      var dir = new Directory(filePath);
      try {
        var under = await dir.list().toList();
        for (FileSystemEntity x in under) {
          var cstat = await x.stat();
          var name = NodeNamer.createName(pathlib.basename(x.path));
          var pa = NodeNamer.joinWithGoodName(node.path, pathlib.basename(x.path));
          var child = node.children[name] = new SimpleNode(pa);
          child.attributes["@fileType"] = FS_TYPE_NAMES[cstat.type];
          child.updateList("@fileType");
        }

        var sub = dir.watch().listen((e) async {
          var rel = pathlib.relative(e.path, from: dir.path);
          if (e.type == FileSystemEvent.CREATE) {
            var x = await getFileSystemEntity(e.path);
            if (x == null) {
              var name = NodeNamer.createName(pathlib.basename(e.path));
              node.children.remove(name);
              node.updateList(name);
              link.removeNode("${node.path}/${name}");
              return;
            }
            var cstat = await x.stat();
            var name = NodeNamer.createName(pathlib.basename(x.path));
            var pa = NodeNamer.joinWithGoodName(node.path, pathlib.basename(x.path));
            var child = node.children[name] = new SimpleNode(pa);
            child.attributes["@fileType"] = FS_TYPE_NAMES[cstat.type];
            node.updateList(name);
          } else if (e.type == FileSystemEvent.DELETE) {
            var name = NodeNamer.createName(pathlib.basename(e.path));
            node.children.remove(name);
            node.updateList(name);
            link.removeNode("${node.path}/${name}");
          }
        });

        node.onRemovingCallback = () {
          if (sub != null) {
            sub.cancel();
          }
        };

        int ops = 0;

        check() {
          if (ops < 0) {
            ops = 0;
          }

          if (ops == 0) {
            node.provider.removeNode(node.path);
          }
        }

        node.onListStartListen = () {
          ops++;
        };

        node.onAllListCancelCallback = () {
          ops--;
          check();
        };

        for (CallbackNode c in node.children.values) {
          c.onListStartListen = () {
            ops++;
          };

          c.onAllListCancelCallback = () {
            ops--;
            check();
          };

          c.onSubscribeCallback = () {
            ops++;
          };

          c.onUnsubscribeCallback = () {
            ops--;
            check();
          };
        }

        node.provider.setNode(node.path, node, registerChildren: true);
      } catch (e) {}
    } else if (stat.type == FileSystemEntityType.FILE) {
      var file = new File(filePath);
      CallbackNode pathNode = new CallbackNode("${node.path}/_@path");
      pathNode.configs.addAll({
        r"$name": "Path",
        r"$type": "string"
      });

      pathNode.updateValue(filePath);

      CallbackNode textContentNode = new CallbackNode("${node.path}/_@text");
      textContentNode.configs.addAll({
        r"$name": "Text",
        r"$type": "string"
      });

      node.children.addAll({
        "_@path": pathNode,
        "_@text": textContentNode
      });

      int ops = 0;

      check() {
        if (ops < 0) {
          ops = 0;
        }

        if (ops == 0) {
          node.provider.removeNode(node.path);
        }
      }

      node.onListStartListen = () {
        ops++;
      };

      node.onAllListCancelCallback = () {
        ops--;
        check();
      };

      for (CallbackNode c in node.children.values) {
        c.onListStartListen = () {
          ops++;
        };

        c.onAllListCancelCallback = () {
          ops--;
          check();
        };

        c.onSubscribeCallback = () async {
          ops++;

          try {
            if (c.path.endsWith("/_@text")) {
              c.updateValue(await file.readAsString());
            }
          } catch (e) {}
        };

        c.onUnsubscribeCallback = () async {
          ops--;
          check();

          try {
            if (c.path.endsWith("/_@text")) {
              c.clearValue();
            }
          } catch (e) {}
        };
      }

      node.provider.setNode(node.path, node, registerChildren: true);
    }

    return true;
  };

  if (Platform.isWindows) {
    pathPlaceholder = r"C:\Users\John Smith";
  } else if (Platform.isMacOS) {
    pathPlaceholder = "/Users/jsmith";
  } else {
    pathPlaceholder = "/home/jsmith";
  }

  provider.nodes["/"].addChild("_@addMount", new SimpleNode("/_@addMount"));

  link.init();

  for (String key in provider.nodes.keys) {
    SimpleNode value = provider.nodes[key];
    if (key.indexOf("/") != key.lastIndexOf("/")) {
      continue;
    }

    if (value.attributes["@directory"] != null) {
      provider.nodes["/"].addChild(key.substring(1), value);
    }
  }

  link.connect();
}

  String pathPlaceholder;

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

class CustomResolvingNodeProvider extends ResolvingNodeProvider {
  CustomResolvingNodeProvider([Map defaultNodes, Map profiles]) :
        super(defaultNodes, profiles);

  @override
  SimpleNode addNode(String path, Map m) {
    if (path == '/' || !path.startsWith('/')) return null;

    Path p = new Path(path);
    SimpleNode pnode = getNode(p.parentPath);

    SimpleNode node;

    if (pnode != null) {
      node = pnode.onLoadChild(p.name, m, this);
    }

    if (node == null) {
      String profile = m[r'$is'];
      if (profileMap.containsKey(profile)) {
        node = profileMap[profile](path);
      } else {
        node = new CallbackNode(path);
      }
    }

    nodes[path] = node;
    node.load(m);

    node.onCreated();

    return node;
  }

  @override
  LocalNode getNode(String path, {Completer<CallbackNode> onLoaded, bool forceHandle: false}) {
    if (path == "" || path == "/") {
      return nodes["/"];
    } else if (path.startsWith("/defs/")) {
      return nodes[path];
    } else if (path == "/_@addMount") {
      return new SimpleActionNode(path, addMountFunction)..configs.addAll({
        r"$name": "Add Mount",
        r"$is": "addMount",
        r"$invokable": "write",
        r"$params": [
          {
            "name": "name",
            "type": "string"
          },
          {
            "name": "directory",
            "type": "string",
            "placeholder": pathPlaceholder,
            "description": "Path to Directory to Mount"
          }
        ],
        r"$result": "values"
      });
    } else {
      return super.getNode(path, onLoaded: onLoaded, forceHandle: forceHandle || path.indexOf("/") == path.lastIndexOf("/"));
    }
  }

  @override
  LocalNode getOrCreateNode(String path, [bool addToTree = true]) {
    if (path.startsWith("/defs")) {
      if (nodes.containsKey(path)) {
        return nodes[path];
      }

      if (addToTree) {
        return createNode(path);
      } else {
        var node = new SimpleNode(path, this);
        return node;
      }
    } else {
      return super.getOrCreateNode(path, addToTree);
    }
  }

  @override
  Map save() {
    var out = {};

    for (String key in nodes.keys) {
      SimpleNode value = nodes[key];
      if (key.indexOf("/") != key.lastIndexOf("/")) {
        continue;
      }

      if (value.attributes["@directory"] != null) {
        out[key.substring(1)] = {
          r"$name": value.configs[r"$name"],
          "@directory": value.attributes["@directory"]
        };
      }
    }

    return out;
  }
}
