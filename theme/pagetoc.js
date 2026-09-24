// 给每章页面顶部注入一个可折叠的小节目录。
// mdBook 的 SUMMARY.md 不允许同一个文件出现两次，所以侧边栏只能做到章级；
// 每章有 8~12 个小节，页内目录是唯一可行的章内导航方式。
(function () {
  'use strict';

  function build() {
    var content = document.querySelector('main');
    if (!content || content.querySelector('details.pagetoc')) return;

    var h1 = content.querySelector('h1');
    if (!h1) return;

    // 只收 ### 级标题，也就是正文里的 "N.M 小节"
    var heads = Array.prototype.filter.call(
      content.querySelectorAll('h3'),
      function (h) { return h.id && h.textContent.trim().length > 0; }
    );
    if (heads.length < 3) return;

    var details = document.createElement('details');
    details.className = 'pagetoc';

    var summary = document.createElement('summary');
    summary.textContent = '本章小节（' + heads.length + '）';
    details.appendChild(summary);

    var ol = document.createElement('ol');
    heads.forEach(function (h) {
      var li = document.createElement('li');
      var a = document.createElement('a');
      a.href = '#' + h.id;
      // 去掉 mdBook 自动追加的锚点符号
      a.textContent = h.textContent.replace(/\u00a7\s*$/, '').trim();
      li.appendChild(a);
      ol.appendChild(li);
    });
    details.appendChild(ol);

    h1.parentNode.insertBefore(details, h1.nextSibling);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', build);
  } else {
    build();
  }
})();
