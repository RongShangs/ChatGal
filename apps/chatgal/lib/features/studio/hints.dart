import 'package:flutter/material.dart';

import '../../design_system/tokens.dart';

/// 一个字段的「一句话说明」+「点开后的详细叙述」。
///
/// 创作台的每个输入项都挂一份：短句永远可见（作者一眼知道该填什么），
/// 点一下展开细节（第一次用的人不用去翻文档）。
class FieldHint {
  const FieldHint(this.brief, this.detail);

  /// 一句话说明（一行内）。
  final String brief;

  /// 展开后的详细叙述（多行，讲清语义、取值范围、常见坑）。
  final String detail;
}

/// 字段说明文案表。键用 `<区域>.<字段>`，由各编辑器按需取用。
const kHints = <String, FieldHint>{
  // ---------------------------------------------------------------- 工程
  'project.identity': FieldHint(
    '工程的身份是目录名，不是包名 —— 同一个包名可以有多份工程。',
    '列表里每个工程对应磁盘上一个目录（工程目录本身就是一棵合法的包目录树）。\n'
        '所以你可以把同一个内容包复制成好几份，各改各的分支，互不影响；'
        '「包名」（manifest 里的 packageId）只决定它装到本地后是不是同一个包。\n'
        '点击工程卡片进入编辑；右侧 ⋮ 是导入到本地包 / 复制 / 重命名 / 导出 / 删除。',
  ),
  'project.install': FieldHint(
    '把这个工程装到本地内容包列表里，装之前会先做版本比对。',
    '装入走的是与「从文件导入内容包」完全相同的那条路：先结构体检，'
        '再算内容哈希，最后原子落盘。\n'
        '版本比对只看一件事：本地有没有同 packageId 的包。\n'
        '· 没有 → 新装；\n'
        '· 有别的版本 → 允许并存（两版同时在列表里，各自带自己的存档）；\n'
        '· 已有同版本号且内容一致 → 会告诉你不必再装；\n'
        '· 已有同版本号但内容不同 → 装不进去（存档是绑在内容哈希上的），'
        '把版本号加一位再装。',
  ),
  'project.duplicate': FieldHint(
    '原地复制一份工程，包名保持一致，适合做分支尝试。',
    '复制出来的是完整目录副本（图也一起复制），新工程名是「原名 副本」，重名时自动加序号。\n'
        '因为工程身份是目录名，复制出来的两份可以共用同一个 packageId —— '
        '装到本地时才会按版本号区分。',
  ),
  'project.delete': FieldHint(
    '删除这个工程（只删工程目录，已装到本地的内容包不受影响）。',
    '删除是不可撤销的：工程目录、里面的图和 JSON 都会一起删掉。\n'
        '如果你只是想让它从本地内容包列表里消失，请在「内容包与存档」里删内容包，不要删工程。',
  ),
  'project.export': FieldHint(
    '把工程打成 .chatgal 文件，可以拿去分享或备份。',
    '导出前会做一次结构体检：有 error 就不导出（避免分享出去一个装不上的包）。\n'
        '导出的是标准 zip：顶层就是包根（manifest.json / home.png / characters / stories / events）。',
  ),
  'project.check': FieldHint(
    '体检 = 用游戏安装包时的那同一套校验器检查这个工程。',
    '体检分成两级：\n'
        '· error（必须修）：缺文件、变量没注册、立绘缺图、出口指向不存在的情景…… 这些会让包装不上；\n'
        '· warning（建议修）：例如某个情景没写出口、home.png 缺失 —— 能装能玩，但体验会差。\n'
        '体检与「装到本地」用的是同一份实现，所以体检通过就一定装得上。',
  ),

  // --------------------------------------------------------------- manifest
  'manifest.packageId': FieldHint(
    '包的唯一标识（例如 top.rongshangs.hellojj.default）。',
    '用反写域名风格，全部小写，用点分段。\n'
        '它决定三件事：装到本地后是不是同一个包、存档能不能继续用、能不能覆盖安装。\n'
        '改了它，就等于换了一个包：原来的存档会变成「包缺失」。\n'
        '建议格式：`com.作者名.包名`。',
  ),
  'manifest.version': FieldHint(
    '版本号，只能是数字，而且只能往高版本升。',
    '例如 `1`、`250`。不能带字母、点或横线。\n'
        '本地已有同包名时：不同版本可以并存；同一个版本号不允许换内容（存档绑在内容上）。\n'
        '打包默认包时脚本会拦「没往高升」的情况；在创作台里装到本地时也会提示当前比对结果。',
  ),
  'manifest.name': FieldHint(
    '游戏里显示的包名（主页标题、内容包与存档页都用它）。',
    '写给人看的名字，可以是中文，例如「你好戒戒」。\n'
        '注意它和 packageId 是两件事：改名不影响存档。',
  ),
  'manifest.description': FieldHint(
    '一两句话介绍这个包，会显示在内容包与存档页。',
    '建议写清「体量 + 玩法」：多少幕、多少结局、什么玩法。\n'
        '它只用于展示，不参与任何判定。',
  ),
  'manifest.home': FieldHint(
    '主页底图：包根那张 home.png（文件名固定，不用在别处声明）。',
    '进游戏之前在主页看到的大图就是它，一般用一张竖版或横版的角色图。\n'
        '选择图片后会以原文件字节存成包根 `home.png` —— 原名是什么都会改名成它。\n'
        '没导入也行：主页会退成主题色，体检只给一条 warning。',
  ),
  'manifest.variables': FieldHint(
    '注册变量：注册过的数值才能在情景里加减、在条件里判断。',
    '所有变量共用一个扁平命名空间：作者在 `fixedEffects`、`vars`、`require` 里'
        '直接写变量自己的 id（可以用中文，如「戒戒好感」）。\n'
        '系统变量 `day` 请一定要保留：天数与剧情分支都靠它。\n'
        '`day` 的默认值写 **0**，新游戏靠「入口那一幕（start）的入场改值 day +1」'
        '变成第 1 天 —— 之后每一天也都在那一天的第一幕 +1。\n'
        '角色属性建议用「角色名+属性」命名（如「戒戒好感」），世界控制台会按角色分组显示。'
        '\n变量的数值只会被两处改变：情景的「入场改值」与「离场结算」。',
  ),
  'var.type': FieldHint(
    '变量类型：int（整数）/ number（小数）/ string（文本）/ bool / enum。',
    '大部分情况用 int。\n'
        '`float` 会被当 number 处理；`fixedEffects` 只能加减数值型变量。\n'
        '字符串/枚举一般用来记状态（例如「当前结局」），但不能参与算术。',
  ),
  'var.bounds': FieldHint(
    '上下限：结算与固定加减的最后一道夹取，越界会被压回边界。留空＝不设那一侧的限制。',
    '建议按「设计上不该越过的范围」来写，例如好感 0~100。\n'
        '**留空就是不设限制**：最大留空表示上限无限（天数 day 通常就只写最小 1），'
        '最小留空表示不设下限。\n'
        '限幅顺序：单次结算上限 → 注册表上下限。上下限是硬边界，'
        '所以写 0~100 就永远不会出现 101。',
  ),
  'var.label': FieldHint(
    '显示名：世界控制台里紧挨着变量 id 的人话名字，例如「好感」。',
    '不填也能用，只是控制台里只显示变量 id。',
  ),

  // --------------------------------------------------------------- character
  'char.id': FieldHint(
    '角色 id：同时是角色目录名与游戏内显示的名字。',
    '目录是 `characters/<id>/`，立绘文件名是 `<状态>_<情绪>.png`。\n'
        '所以 id 建议用短的中文名（如「戒戒」），它不能带 `/` 或空格。\n'
        '包里有几个角色文件夹，游戏内就有几个角色。',
  ),
  'char.prompt': FieldHint(
    '角色基础提示词：她是谁 —— 每次对话都会带上这一段。',
    '写稳定的人设：身份、性格、说话方式、动作习惯、边界（不承认自己是 AI 等）。\n'
        '不要在这里写具体剧情 —— 每幕的情境写在对应情景的「本幕提示词」里，'
        '两者会拼在一起送进模型。\n'
        '写得越具体越稳：例如「短句为主，常有停顿；动作一律用全角括号」比「要像内向的人」有效得多。',
  ),
  'char.states': FieldHint(
    '状态：服装 × 形态的组合词，例如「校服」「睡裙」「便服」「校服猫化」。',
    '一个状态 = 一套外观。游戏里同一幕只允许在这一个状态内换表情（不跨服装/形态）。\n'
        '改名会同时把已有的立绘文件重命名成新名字，不会丢图。\n'
        '状态名里不要用下划线：文件名是「状态_情绪」，下划线用来分隔两者。',
  ),
  'char.emotions': FieldHint(
    '情绪：模型可以逐段选的表情词，例如「平常 / 开心 / 伤心 / 害羞 / 生气 / 惊讶 / 思考 / 感动 / 失落」。',
    '这些词会作为「可用情绪」提交给模型，模型每段都要选一个。\n'
        '名字要短、彼此区别明显；同义词太多会让模型犹豫。\n'
        '改名会同步重命名立绘文件。',
  ),
  'char.defaults': FieldHint(
    '默认状态 / 默认情绪：情景没有声明时用它，也是解析立绘时的兜底。',
    '必须从你声明过的状态/情绪里选（否则体检报错）。\n'
        '「默认状态_默认情绪」这一张立绘建议一定要有：模型答了表外的词时会兜底到它。',
  ),
  'char.portraits': FieldHint(
    '立绘矩阵：每个「状态 × 情绪」都要有一张图，缺一张体检就会报错。',
    '点格子导入图片；导入时会**复制进工程目录**并按「状态_情绪.png」自动命名，'
        '所以工程是自足的，导出就是完整包。\n'
        '建议同一状态的图用同一套画风、同一尺寸与构图，游戏里逐段切图才不会跳。\n'
        '图片格式用 png（支持透明底），文件名里的下划线由系统处理，你不用自己改文件名。',
  ),

  // ------------------------------------------------------------------- scene
  'scene.list': FieldHint(
    '情景 = 一幕。文件名就是它的 id，`start.json` 是游戏的入口。',
    '游戏从 `stories/start.json` 开始，之后按每幕的「出口」一幕幕走下去。\n'
        '所有情景都是扁平的：直接放在 `stories/` 下，不要建子目录（加载器只认第一层）。\n'
        '想不通怎么连的时候，先画一遍链条：第 1 天白天 → 傍晚 → 晚上 → 第 2 天白天……',
  ),
  'scene.displayName': FieldHint(
    '情景展示名：左上角显示「第 N 天 · 展示名」，例如「白天·学校」。',
    '写「时段·地点」最直观。名字太长会被截断/走马灯。',
  ),
  'scene.background': FieldHint(
    '背景图：`stories/` 下的图片文件名，例如 `ji_q.png`。',
    '包里的背景图可以多幕共用，不必每幕拷一份。\n'
        '留空则显示主题色（不报错）。\n'
        '文件不存在会被体检拦下 —— 别写路径，只写文件名。',
  ),
  'scene.narration': FieldHint(
    '入场词：进入这一幕时显示在对话流顶部的那段场景叙述。',
    '写成第三人称的场景卡：现在在哪、什么时候、她什么状态。\n'
        '这段是给玩家看的（不参与判定），但它也是模型理解「现在发生了什么」的重要线索。',
  ),
  'scene.atmosphere': FieldHint(
    '转场气氛：**写了这一句，切进这一幕时才会播过场动画**（并显示它 + 展示名 + 天数）。',
    '一句环境/天气/情绪的短句，例如「雨点敲打着出租屋的窗户，屋里格外安静。」\n'
        '留空 = 切进这一幕**不播过场**，直接静默换幕（同一时段里的快节奏切换可以这么写）。\n'
        '过场里显示的天数是**算完这一幕入场改值之后**的天数（所以新一天第一幕的那次过场，'
        '直接显示新的天数）。',
  ),
  'scene.characters': FieldHint(
    '出场角色：这一幕有谁在，锁定哪套立绘，以及本幕的人格提示词。',
    '不在这个列表里的角色，等于**不在场**：他看不到这一幕的对话，也不会记住它。\n'
        'state/emotion 决定本幕可用的立绘集合（模型只能在这套 state 内换表情）。\n'
        '多角色时每人都写一条，各自可以有不同的本幕提示词。',
  ),
  'scene.scenePrompt': FieldHint(
    '本幕提示词：这一幕的情境、她的态度、这一幕该推进什么。',
    '它和角色基础人格拼在一起送进模型。建议包含四件事：\n'
        '① 时间地点（第几天、白天还是晚上、在哪）；\n'
        '② 当下情境（刚发生了什么、场面是什么样）；\n'
        '③ 她的状态与态度（对你戒备？依赖？）；\n'
        '④ 不要做什么（别提前跳到后面几天、别宣布结局）。\n'
        '写成给人看的说明，不要写成命令列表。',
  ),
  'scene.fixedEffects': FieldHint(
    '进入本幕时改的值：正数为加、负数为减（例如 day +1）。',
    '游戏靠这一步推进天数：**每一天的第一幕**（含入口 start）写「day 加 1」——'
        '`day` 默认 0，所以开局进 start 时 +1 就是第 1 天。\n'
        '只能改**数值**变量，value 不能为 0（没意义）。\n'
        '注意它是**进入时**执行：所以要写在天数变化后的那一幕上，不要写在前一幕的离场上。',
  ),
  'scene.settlement': FieldHint(
    '离场结算：让 AI 按本幕对话给某些数值加减 —— **每个变量一个块**，各写各的判定标准。',
    '一个块 = 一个受控变量。四件事：\n'
        '· 变量：必须是注册过的数值变量（好感 / 信任 / 服从 / 堕落，或你自己加的）；\n'
        '· 判定提示词：**这一个变量**该怎么看（例如「有没有更亲近的举动」），这是它和别的变量不同的地方；\n'
        '· 单次上限：这个变量单次最多加减多少（重要转折幕可以给 5，平时 3 就够）；\n'
        '· 无证据时：zero＝保持原值照常换幕；abort＝拒绝本次离场（容易卡住玩家，谨慎用）。\n'
        '同一幕对同一个变量只能有一个块；不写任何块就是本幕不结算。\n'
        '引擎发一次请求就把所有块的说明一起交给模型，因此每个增量都会被各自的单次上限收口；\n'
        '同一幕只结算一次：重试或崩溃重放都不会重复加。',
  ),
  'settlement.prompt': FieldHint(
    '判定提示词：只针对这一个变量，写清「出现什么表现算加、什么算减、看不出来怎么办」。',
    '要点：\n'
        '· 写成「是否出现某种**可观察的表现**」，而不是「根据剧情给分」——后者会让模型自由发挥；\n'
        '· 明确正负方向（更亲近给正、更疏远给负），并明确「看不出来就给 0」；\n'
        '· 不要写具体数值上限（那由「单次上限」管），也不要提别的变量（每个块各管各的）。\n'
        '例：「她有没有主动靠近你、在意你的反应？有明确证据给 +1/+2；明显回避给 -1；看不出来 0。」',
  ),
  'settlement.max': FieldHint(
    '单次上限：这一个变量在一次离场结算里，最多能加减多少。',
    '它是逐维夹取（每个变量各自算），不是所有变量共用一个数字。\n'
        '官方默认包里：日常幕 3，转折幕（生死判定、真相揭露、终局）给到 5。\n'
        '再往上还会被变量自己的注册上下限夹住，所以这里写大一点也不会越界。',
  ),
  'scene.onNoEvidence': FieldHint(
    '这个变量拿不到证据时怎么办：zero = 保持原值（推荐）；abort = 拒绝本次离场。',
    '`zero`：这一幕这个变量不加不减，玩家照常进入下一幕 —— 绝大多数情况该用它。\n'
        '`abort`：把整次离场退回原情景、可重试（玩家会看到提示）。'
        '只有「这个变量必须结算成功才能继续」时才用，否则容易卡住玩家。',
  ),
  'scene.target': FieldHint(
    '出口：这一幕聊完之后去哪。自上而下看，第一个条件成立的那一块生效。',
    '每一块 = 一个条件（可留空＝无条件）+ 一组目的地。\n'
        '· 顺序就是优先级：上面先判，命中就停；\n'
        '· 同一块里写了多个目的地时，**等概率**随机取一个（写两个一样的，就等于给它双倍概率）；\n'
        '· 最后一块建议不写条件，当保底；\n'
        '· 一块都不成立（或干脆没写出口）时，玩家点「下一阶段」会看到「暂时不能进入下一阶段噢」，'
        '留在原地继续聊天 —— 这是合法状态，不是错误。',
  ),
  'target.require': FieldHint(
    '条件：一段中缀表达式，例如 `"day" == 14 & "戒戒好感" < 60`。留空＝无条件成立。',
    '变量名必须用双引号包起来；数字直接写。\n'
        '比较：`>` `<` `>=` `<=` `==` `!=`；逻辑：`&`（与）`|`（或）`!`（非）；'
        '算术：`+` `-`；可以用括号，例如 `("戒戒好感" + "戒戒信任") < 120`。\n'
        '`day` 读的是**本幕所属那一天**（因为 day+1 写在下一幕的入场效果里），'
        '所以「第 7 天最后一场聊完」就写 `"day" == 7`。\n'
        '写错语法或引用了没注册的变量，体检会直接报出来。',
  ),
  'target.kind': FieldHint(
    '目的地：去哪一幕（story）、去哪个事件（event），还是回主页（appShell）。',
    '`story` 后面选 `stories/` 里的某一幕；\n'
        '`event` 后面选 `events/` 里的某个事件；\n'
        '`appShell` 是回主页，固定写 `home`。\n'
        '同一个出口块里可以放多个目的地：**等概率随机取一个**（这里没有权重字段）。\n'
        '想给某个目标更大机会，就把同一个目标**再加一次**——两个一样的选项等于它的概率翻倍。',
  ),

  // ------------------------------------------------------------------- event
  'event.choice': FieldHint(
    '事件的出口二选一：出口块 target（按条件/随机）或选择题 choice（玩家自己选）。',
    '`target`：和情景完全同一套写法 —— 自上而下首个条件成立的块生效，块内等概率随机。\n'
        '`choice`：**事件专有**。播完最后一屏后，把选项铺在屏幕上让玩家点，'
        '点哪个就去哪个 —— 选项里不用写条件、不用管数值、也不随机。\n'
        '两者是**二选一**：保存时会写一个、清掉另一个；两个都写在文件里体检会报错。\n'
        '典型用法：结局播完问一句「回主页，还是继续留在这里」，把「继续」接到后续情景。',
  ),
  'event.choiceOptions': FieldHint(
    '选择题的标题与选项：标题是问题上那句话（可留空），选项最多 5 个。',
    '每个选项 = 按钮上的字 + 去哪（情景 / 事件 / 回主页）。\n'
        '按钮文字建议用第一人称或明确动作（「回到主页」「继续留在这里」），'
        '别写「选项一」这种玩家看不懂的占位。\n'
        '选项顺序就是屏幕上的顺序；想调顺序用上下箭头。',
  ),
  'event.list': FieldHint(
    '事件 = 一段不能对话的演出（全屏插图 + 逐句点击推进），常用于结局。',
    '文件夹名就是事件 id，也是世界控制台里显示的名字（不需要额外起名）。\n'
        '事件播完同样走「出口」那套判定，所以可以接下一个事件或切到某个情景。',
  ),
  'event.slides': FieldHint(
    '演出分块：**一块 = 一屏**（一张图 + 这一屏的全部文字），点一下翻下一块。',
    '块内写多句会**换行显示在同一屏**，所以一句话一行、别写太长（一两行最好）。\n'
        '想让同一张图连续出现两屏，第二块的图留空（沿用上一张）。\n'
        '整段演出播完后按「出口」离开。',
  ),
  'slide.image': FieldHint(
    '这一块的图：写事件自己目录下的文件名（例如 cover.png）；留空＝沿用上一张。',
    '导入图片时会复制进 `events/<事件id>/`。\n'
        '留空（沿用上一张）适合「同一张 CG 配多句台词」。\n'
        '文件不存在体检会报错。',
  ),
  'slide.text': FieldHint(
    '这一屏的文字（一行一句，全部显示在同一屏里）。',
    '一行一句；建议短句、有节奏（配音/旁白式的一屏不要超过 4~5 行）。\n'
        '空着一块会是一屏空白，体检会给出 warning。',
  ),

  // ----------------------------------------------------------------- 其它
  'studio.new': FieldHint(
    '从零新建一个内容包工程。',
    '会自动建好最小结构：manifest（含系统变量 day）+ 一个空的 `stories/start.json`'
        '（入口）+ 空的 characters/ 与 events/ 目录。\n'
        '新建后建议的动手顺序：① 填包名与版本；② 建角色并导入立绘；③ 写第 1 天情景；'
        '④ 体检；⑤ 装到本地试玩。',
  ),
  'studio.import': FieldHint(
    '把一个 .chatgal（或 zip）导入成工程。',
    '导入只读文件、不改动原文件；解压出来的目录树就是工程。\n'
        '也可以从「已装到本地的内容包」直接导入成工程（复制一份，原包不动）。',
  ),
};

/// 字段标签 + ⓘ：点一下展开/收起详细叙述。
class HintLabel extends StatefulWidget {
  const HintLabel({
    super.key,
    required this.theme,
    required this.title,
    required this.hintKey,
    this.required = false,
  });

  final ChatGalTheme theme;
  final String title;
  final String hintKey;
  final bool required;

  @override
  State<HintLabel> createState() => _HintLabelState();
}

class _HintLabelState extends State<HintLabel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.theme;
    final hint = kHints[widget.hintKey];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: t.ink,
              ),
            ),
            if (widget.required)
              Text(' *', style: TextStyle(fontSize: 13, color: t.accent)),
            const SizedBox(width: 6),
            if (hint != null)
              InkWell(
                onTap: () => setState(() => _open = !_open),
                borderRadius: BorderRadius.circular(10),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                        _open
                            ? Icons.expand_less_rounded
                            : Icons.info_outline_rounded,
                        size: 15,
                        color: t.accent,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        _open ? '收起' : '说明',
                        style: TextStyle(fontSize: 11, color: t.accent),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        if (hint != null) ...[
          const SizedBox(height: 3),
          Text(
            hint.brief,
            style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
          ),
        ],
        if (_open && hint != null) ...[
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: t.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: t.accent.withValues(alpha: 0.25)),
            ),
            child: Text(
              hint.detail,
              style: TextStyle(fontSize: 11.5, height: 1.65, color: t.ink),
            ),
          ),
        ],
        const SizedBox(height: 6),
      ],
    );
  }
}

/// 创作台里所有输入框的统一样式（四个编辑器 + 它们弹出的对话框）。
///
/// 目的是让作者**一眼分清「这是提示」还是「我已经填了」**：
/// * 底色用页面底色 `bg`（不是卡片色）—— 字段的边界看得见，空着也看得见；
/// * 提示文字明显更浅，而且示例一律以「例：」开头（见各处的 `hintText`）。
InputDecorationTheme studioInputTheme(ChatGalTheme t) => InputDecorationTheme(
      filled: true,
      fillColor: t.bg,
      hintStyle: TextStyle(
        color: t.sub.withValues(alpha: 0.55),
        fontSize: 13,
        height: 1.5,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.sub.withValues(alpha: 0.28)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.sub.withValues(alpha: 0.28)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: t.accent, width: 1.2),
      ),
    );

/// 段落标题（带一句总说明）。
class StudioSection extends StatelessWidget {
  const StudioSection({
    super.key,
    required this.theme,
    required this.title,
    required this.hintKey,
    required this.child,
  });

  final ChatGalTheme theme;
  final String title;
  final String hintKey;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: t.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: t.sub.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: t.ink,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            kHints[hintKey]?.brief ?? '',
            style: TextStyle(fontSize: 11.5, height: 1.5, color: t.sub),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}

/// 统一样式的下拉框（创作台公共件：情景 / 事件 / 条件编辑器都用它）。
///
/// 直接用 [DropdownButton]（不用 DropdownButtonFormField：它的 `value` 已废弃）。
/// 当 [value] 不在 [options] 里（内容包被外部改过 / 目标被删掉）时自动补一个
/// 带 ⚠ 的选项，避免 Dropdown 的断言直接把页面炸掉。
class StudioDropdown<T> extends StatelessWidget {
  const StudioDropdown({
    super.key,
    required this.theme,
    required this.value,
    required this.options,
    this.onChanged,
    this.placeholder = '（未选择）',
    this.width,
    this.dense = false,
  });

  final ChatGalTheme theme;
  final T? value;

  /// (值, 显示文字)
  final List<(T, String)> options;
  final ValueChanged<T?>? onChanged;
  final String placeholder;
  final double? width;

  /// 紧凑模式：字更小、内边距更小（条件行那种一行放三个控件的地方用）。
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final t = theme;
    final fontSize = dense ? 12.0 : 13.0;
    final items = <DropdownMenuItem<T>>[
      for (final o in options)
        DropdownMenuItem<T>(
          value: o.$1,
          child: Text(
            o.$2,
            style: TextStyle(fontSize: fontSize, color: t.ink),
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];
    final hasValue = value != null && !options.any((o) => o.$1 == value);
    if (hasValue) {
      items.insert(
        0,
        DropdownMenuItem<T>(
          value: value,
          child: Text(
            '$value ⚠ 不在当前可选项中',
            style: TextStyle(fontSize: fontSize, color: Colors.red),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
    }

    final box = Container(
      width: width,
      padding: EdgeInsets.symmetric(horizontal: dense ? 8 : 10),
      decoration: BoxDecoration(
        color: dense ? t.card : t.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.sub.withValues(alpha: 0.25)),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: dense,
          isExpanded: true,
          hint: Text(
            placeholder,
            style: TextStyle(fontSize: fontSize, color: t.sub),
            overflow: TextOverflow.ellipsis,
          ),
          icon: Icon(Icons.expand_more_rounded, size: 18, color: t.sub),
          dropdownColor: t.card,
          borderRadius: BorderRadius.circular(12),
          items: items,
          onChanged: onChanged,
        ),
      ),
    );

    // 一个选项都没有、也没选值时：不给一个点了没反应的下拉框。
    if (options.isEmpty && value == null && onChanged != null) {
      return Container(
        width: width,
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 10,
          vertical: dense ? 8 : 9,
        ),
        decoration: BoxDecoration(
          color: dense ? t.card : t.bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: t.sub.withValues(alpha: 0.25)),
        ),
        child: Text(
          placeholder,
          style: TextStyle(fontSize: fontSize, color: t.sub),
          overflow: TextOverflow.ellipsis,
        ),
      );
    }
    return box;
  }
}
