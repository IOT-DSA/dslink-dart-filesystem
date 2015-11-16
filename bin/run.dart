import "package:dslink/dslink.dart";
import "package:dslink/nodes.dart";

import "dart:io";

import "package:path/path.dart" as pathlib;

LinkProvider link;

main(List<String> args) async {
  var np = new ResolvingNodeProvider();
  link = new LinkProvider(args, "FileSystem-", provider: np, autoInitialize: false);

  np.handler = (CallbackNode node) async {
    List<String> parts = node.path.split("/").map(NodeNamer.decodeName).toList();

    if (node.path == "/") {
      for (var key in mounts.keys) {
        node.addChild(key, new SimpleNode("/${key}"));
      }
      return true;
    }

    String filePath;

    if (mounts.containsKey(parts[1])) {
      filePath = pathlib.join(mounts[parts[1]], parts.skip(2).join("/"));
    } else {
      return false;
    }

    var stat = await FileStat.stat(filePath);
    if (stat.type == FileSystemEntityType.NOT_FOUND) {
      return false;
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
        }
      } catch (e) {}
    } else if (stat.type == FileSystemEntityType.FILE) {
      var file = new File(filePath);
      CallbackNode pathNode = node.createChild("_@path", {
        r"$name": "Path",
        r"$type": "string",
        "?value": filePath
      });

      CallbackNode getDataNode = node.createChild("_@getTextContent", {
        r"$name": "Get Text Content",
        r"$invokable": "read",
        r"$params": [],
        r"$columns": [
          {
            "name": "content",
            "type": "string",
            "editor": "textarea"
          }
        ],
        r"$result": "values"
      });

      getDataNode.onActionInvoke = (Map<String, dynamic> params) async {
        return {
          "content": await file.readAsString()
        };
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
    }

    return true;
  };

  link.init();
  link.connect();
}

Map<FileSystemEntityType, String> FS_TYPE_NAMES = {
  FileSystemEntityType.DIRECTORY: "directory",
  FileSystemEntityType.FILE: "file"
};

Map<String, String> mounts = {
  "default": "home"
};
