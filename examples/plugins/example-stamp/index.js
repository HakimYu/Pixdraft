// 示例插件：脚本自己不做任何图片处理，只描述要执行的本地操作。
// 宿主会把 operations 交给本地处理模块（resize / watermark），全程离线。

function stamp(payload) {
  var params = payload.params || {};
  var text = (params.text || '示例工作室').trim();
  if (!text) throw new Error('水印文字不能为空');
  var opacity = typeof params.opacity === 'number' ? params.opacity : 0.6;
  var position = typeof params.position === 'string' ? params.position : '右下';
  return {
    operations: [
      {operation: 'watermark', params: {text: text + ' · 示例', position: position, opacity: opacity, scale: 0.08}},
      {operation: 'watermark', params: {text: '插件示例', position: '左上', opacity: 0.35, scale: 0.05}}
    ]
  };
}

// 工具入口与处理器共用同一个脚本函数，宿主按清单声明分发。
function stampTool(payload) {
  return stamp(payload);
}