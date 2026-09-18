from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import cm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    BaseDocTemplate,
    Frame,
    KeepTogether,
    PageBreak,
    PageTemplate,
    Paragraph,
    Spacer,
    Table,
    TableStyle,
)


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "output" / "pdf" / "resolucao_algebra_linear_lista1_dre65.pdf"

FONT_DIR = Path("/System/Library/Fonts/Supplemental")
pdfmetrics.registerFont(TTFont("Arial", str(FONT_DIR / "Arial.ttf")))
pdfmetrics.registerFont(TTFont("Arial-Bold", str(FONT_DIR / "Arial Bold.ttf")))
pdfmetrics.registerFont(TTFont("CourierNew", str(FONT_DIR / "Courier New.ttf")))
pdfmetrics.registerFont(TTFont("CourierNew-Bold", str(FONT_DIR / "Courier New Bold.ttf")))

PAGE_W, PAGE_H = A4
MARGIN_X = 1.8 * cm
MARGIN_TOP = 2.0 * cm
MARGIN_BOTTOM = 1.8 * cm

NAVY = colors.HexColor("#17324D")
BLUE = colors.HexColor("#2B6CB0")
PALE_BLUE = colors.HexColor("#EAF2F8")
PALE_GREEN = colors.HexColor("#EAF7EF")
GREEN = colors.HexColor("#247A4D")
PALE_GOLD = colors.HexColor("#FFF6DA")
GOLD = colors.HexColor("#9A6B00")
INK = colors.HexColor("#17212B")
MUTED = colors.HexColor("#536273")
RULE = colors.HexColor("#D7DEE6")
CODE_BG = colors.HexColor("#F5F7FA")


styles = getSampleStyleSheet()
styles.add(
    ParagraphStyle(
        name="CoverTitle",
        fontName="Arial-Bold",
        fontSize=25,
        leading=31,
        textColor=NAVY,
        alignment=TA_CENTER,
        spaceAfter=14,
    )
)
styles.add(
    ParagraphStyle(
        name="CoverSub",
        fontName="Arial",
        fontSize=12,
        leading=18,
        textColor=MUTED,
        alignment=TA_CENTER,
    )
)
styles.add(
    ParagraphStyle(
        name="H1Custom",
        fontName="Arial-Bold",
        fontSize=18,
        leading=22,
        textColor=NAVY,
        spaceBefore=2,
        spaceAfter=9,
        keepWithNext=True,
    )
)
styles.add(
    ParagraphStyle(
        name="H2Custom",
        fontName="Arial-Bold",
        fontSize=12.5,
        leading=16,
        textColor=BLUE,
        spaceBefore=10,
        spaceAfter=5,
        keepWithNext=True,
    )
)
styles.add(
    ParagraphStyle(
        name="H3Custom",
        fontName="Arial-Bold",
        fontSize=10.5,
        leading=14,
        textColor=INK,
        spaceBefore=7,
        spaceAfter=3,
        keepWithNext=True,
    )
)
styles.add(
    ParagraphStyle(
        name="BodyCustom",
        fontName="Arial",
        fontSize=10.2,
        leading=15.2,
        textColor=INK,
        spaceAfter=6,
    )
)
styles.add(
    ParagraphStyle(
        name="SmallCustom",
        fontName="Arial",
        fontSize=8.7,
        leading=12.5,
        textColor=MUTED,
        spaceAfter=4,
    )
)
styles.add(
    ParagraphStyle(
        name="Equation",
        fontName="CourierNew",
        fontSize=9.6,
        leading=14,
        textColor=INK,
        leftIndent=4,
        rightIndent=4,
    )
)
styles.add(
    ParagraphStyle(
        name="Answer",
        fontName="Arial-Bold",
        fontSize=11,
        leading=14,
        textColor=GREEN,
    )
)
styles.add(
    ParagraphStyle(
        name="TOC",
        fontName="Arial",
        fontSize=9.5,
        leading=13.5,
        textColor=INK,
    )
)


def header_footer(canvas, doc):
    canvas.saveState()
    if doc.page > 1:
        canvas.setStrokeColor(RULE)
        canvas.setLineWidth(0.5)
        canvas.line(MARGIN_X, PAGE_H - 1.22 * cm, PAGE_W - MARGIN_X, PAGE_H - 1.22 * cm)
        canvas.setFont("Arial-Bold", 8.5)
        canvas.setFillColor(NAVY)
        canvas.drawString(MARGIN_X, PAGE_H - 0.92 * cm, "Algebra Linear - Lista 1 - DRE terminado em 65")
        canvas.setFont("Arial", 8.5)
        canvas.setFillColor(MUTED)
        canvas.drawRightString(PAGE_W - MARGIN_X, 0.85 * cm, f"Página {doc.page}")
    canvas.restoreState()


frame = Frame(
    MARGIN_X,
    MARGIN_BOTTOM,
    PAGE_W - 2 * MARGIN_X,
    PAGE_H - MARGIN_TOP - MARGIN_BOTTOM,
    id="normal",
)

doc = BaseDocTemplate(
    str(OUTPUT),
    pagesize=A4,
    leftMargin=MARGIN_X,
    rightMargin=MARGIN_X,
    topMargin=MARGIN_TOP,
    bottomMargin=MARGIN_BOTTOM,
    title="Resolução de Álgebra Linear - Lista 1 - DRE terminado em 65",
    author="Material de estudo organizado com Codex",
    subject="Resolução passo a passo dos exercícios Q1 a Q16",
)
doc.addPageTemplates([PageTemplate(id="content", frames=[frame], onPage=header_footer)])

story = []


def p(text, style="BodyCustom"):
    story.append(Paragraph(text, styles[style]))


def h1(text):
    story.append(Paragraph(text, styles["H1Custom"]))


def h2(text):
    story.append(Paragraph(text, styles["H2Custom"]))


def h3(text):
    story.append(Paragraph(text, styles["H3Custom"]))


def equation(*lines):
    content = "<br/>".join(lines)
    box = Table([[Paragraph(content, styles["Equation"]) ]], colWidths=[PAGE_W - 2 * MARGIN_X])
    box.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), CODE_BG),
                ("BOX", (0, 0), (-1, -1), 0.5, RULE),
                ("LEFTPADDING", (0, 0), (-1, -1), 9),
                ("RIGHTPADDING", (0, 0), (-1, -1), 9),
                ("TOPPADDING", (0, 0), (-1, -1), 7),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    story.append(box)
    story.append(Spacer(1, 6))


def note(text):
    box = Table([[Paragraph(text, styles["BodyCustom"]) ]], colWidths=[PAGE_W - 2 * MARGIN_X])
    box.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), PALE_GOLD),
                ("LINEBEFORE", (0, 0), (0, -1), 3, GOLD),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 7),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    story.append(box)
    story.append(Spacer(1, 6))


def answer(text):
    box = Table([[Paragraph(f"Resposta: {text}", styles["Answer"]) ]], colWidths=[PAGE_W - 2 * MARGIN_X])
    box.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), PALE_GREEN),
                ("BOX", (0, 0), (-1, -1), 0.8, colors.HexColor("#B9DFC9")),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 10),
                ("TOPPADDING", (0, 0), (-1, -1), 8),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 8),
            ]
        )
    )
    story.append(box)
    story.append(Spacer(1, 7))


def new_question(number, title):
    if number != 1:
        story.append(PageBreak())
    badge = Table(
        [[Paragraph(f"Q{number}", styles["Answer"]), Paragraph(title, styles["H1Custom"]) ]],
        colWidths=[1.5 * cm, PAGE_W - 2 * MARGIN_X - 1.5 * cm],
    )
    badge.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (0, 0), PALE_GREEN),
                ("BOX", (0, 0), (0, 0), 0.8, colors.HexColor("#B9DFC9")),
                ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                ("LEFTPADDING", (0, 0), (-1, -1), 7),
                ("RIGHTPADDING", (0, 0), (-1, -1), 7),
                ("TOPPADDING", (0, 0), (-1, -1), 5),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
            ]
        )
    )
    story.append(badge)
    story.append(Spacer(1, 8))


# Cover
story.append(Spacer(1, 3.0 * cm))
story.append(Paragraph("Álgebra Linear", styles["CoverTitle"]))
story.append(Paragraph("Lista 1 - agosto de 2026", styles["CoverSub"]))
story.append(Spacer(1, 0.55 * cm))
cover_box = Table(
    [[Paragraph("Resolução completa e comentada", styles["H1Custom"])],
     [Paragraph("DRE terminado em 65 - exercícios Q1 a Q16", styles["CoverSub"])]],
    colWidths=[PAGE_W - 2 * MARGIN_X],
)
cover_box.setStyle(
    TableStyle(
        [
            ("BACKGROUND", (0, 0), (-1, -1), PALE_BLUE),
            ("BOX", (0, 0), (-1, -1), 1, colors.HexColor("#BED3E8")),
            ("ALIGN", (0, 0), (-1, -1), "CENTER"),
            ("TOPPADDING", (0, 0), (-1, -1), 13),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 13),
        ]
    )
)
story.append(cover_box)
story.append(Spacer(1, 1.1 * cm))
p("Material pensado para quem está no início da disciplina. Cada exercício apresenta o conceito utilizado, as contas em sequência, a verificação da resposta e um método alternativo quando ele realmente simplifica o problema.", "CoverSub")
story.append(Spacer(1, 4.6 * cm))
p("Escopo: foi considerada somente a lista do DRE terminado em 65. Fragmentos do DRE 64 visíveis nas bordas das capturas não pertencem a este material.", "SmallCustom")

# Gabarito and quick concepts
story.append(PageBreak())
h1("Gabarito geral")
answers = [
    ["Q1", "B", "Q2", "F", "Q3", "E: k = -4", "Q4", "B"],
    ["Q5", "A: k = -1", "Q6", "F: r ≈ 47,5", "Q7", "E: x1 = 6", "Q8", "B"],
    ["Q9", "F", "Q10", "E: z = -6", "Q11", "D", "Q12", "C: dim = 11"],
    ["Q13", "C: dim = 2", "Q14", "B", "Q15", "E: c = 1", "Q16", "B"],
]
table = Table(answers, colWidths=[0.75*cm, 2.85*cm, 0.75*cm, 2.85*cm, 0.75*cm, 2.85*cm, 0.75*cm, 2.85*cm])
table.setStyle(
    TableStyle(
        [
            ("FONTNAME", (0, 0), (-1, -1), "Arial"),
            ("FONTNAME", (0, 0), (-1, -1), "Arial-Bold"),
            ("FONTSIZE", (0, 0), (-1, -1), 8.3),
            ("TEXTCOLOR", (0, 0), (-1, -1), INK),
            ("BACKGROUND", (0, 0), (-1, -1), colors.white),
            ("ROWBACKGROUNDS", (0, 0), (-1, -1), [colors.white, CODE_BG]),
            ("GRID", (0, 0), (-1, -1), 0.5, RULE),
            ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
            ("LEFTPADDING", (0, 0), (-1, -1), 5),
            ("RIGHTPADDING", (0, 0), (-1, -1), 5),
            ("TOPPADDING", (0, 0), (-1, -1), 7),
            ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
        ]
    )
)
story.append(table)
story.append(Spacer(1, 14))
h2("Ideias básicas usadas na lista")
p("<b>Span:</b> o conjunto de todas as combinações lineares dos vetores apresentados. Por exemplo, span{u,v} contém todos os vetores da forma au+bv.")
p("<b>LI - linearmente independente:</b> nenhum vetor do conjunto pode ser obtido como combinação dos outros. A combinação que produz o vetor zero só pode ter todos os coeficientes iguais a zero.")
p("<b>LD - linearmente dependente:</b> existe uma combinação não trivial que produz o vetor zero. Em particular, dois vetores são LD quando um é múltiplo do outro.")
p("<b>Dimensão:</b> número de direções independentes. Em um sistema consistente com três variáveis, duas equações independentes deixam uma variável livre e formam uma reta, de dimensão 1.")
p("<b>Subespaço:</b> precisa conter o vetor zero e permanecer fechado quando somamos vetores ou multiplicamos por escalares.")
note("Sugestão de estudo: tente refazer cada exercício escondendo a resolução. Depois compare não apenas a alternativa, mas também em qual linha seu cálculo começou a divergir.")

# Q1
new_question(1, "Equação paramétrica de um plano")
p("O plano é dado por <b>7x - 2y + z = 3</b>. Uma parametrização precisa conter um ponto do plano e duas direções independentes paralelas a ele.")
h2("Método rápido - testar a alternativa")
p("Na alternativa (B), o ponto inicial é P = (1,-1,-6). Substituímos suas coordenadas na equação do plano:")
equation("7(1) - 2(-1) + (-6) = 7 + 2 - 6 = 3")
p("Logo, P pertence ao plano. Agora testamos os vetores-direção u = (-2,0,14) e v = (0,-4,-8). Para uma direção (a,b,c) ser paralela ao plano, deve valer 7a - 2b + c = 0.")
equation("u: 7(-2) - 2(0) + 14 = -14 + 14 = 0", "v: 7(0) - 2(-4) - 8 = 8 - 8 = 0")
p("Os dois vetores não são múltiplos entre si, portanto representam duas direções independentes.")
equation("x = (1,-1,-6) + t(-2,0,14) + s(0,-4,-8)")
h2("Método convencional - construir a parametrização")
p("Escolhemos y = s e z = t como variáveis livres. A equação fica:")
equation("7x - 2s + t = 3", "7x = 3 + 2s - t", "x = 3/7 + (2/7)s - (1/7)t")
p("Separando o ponto fixo e as direções:")
equation("(x,y,z) = (3/7,0,0) + s(2/7,1,0) + t(-1/7,0,1)")
p("Essa forma é diferente da alternativa, mas descreve exatamente o mesmo plano. Um plano admite muitas parametrizações.")
answer("alternativa (B)")

# Q2
new_question(2, "Dimensão dos conjuntos-solução")
p("Em R³, uma equação independente normalmente deixa duas variáveis livres; duas equações independentes deixam uma variável livre; três equações independentes determinam um ponto. Procuramos a opção em que os dois sistemas têm dimensão 1.")
h2("Alternativa (A)")
p("No primeiro sistema, (-18,-27,-15) é 3/5 de (-30,-45,-25). Há uma única equação independente e dimensão 2. No segundo, a terceira equação é cinco vezes a segunda; junto da primeira ficam duas equações independentes e dimensão 1.")
equation("A: dimensões 2 e 1")
h2("Alternativa (B)")
p("O primeiro sistema contém duas equações independentes, então tem dimensão 1. No segundo sistema, a segunda equação é 3/5 da primeira, deixando somente uma equação independente e dimensão 2.")
equation("B: dimensões 1 e 2")
h2("Alternativa (C)")
p("As duas equações do primeiro sistema não são múltiplas, logo sua dimensão é 1. No segundo, (12,21,9,24) é 3/5 de (20,35,15,40), logo a dimensão é 2.")
equation("C: dimensões 1 e 2")
h2("Alternativa (D)")
p("No primeiro sistema, y = 2. A segunda equação determina z e a primeira determina x. A solução é um ponto, de dimensão 0. O segundo sistema possui duas equações independentes e dimensão 1.")
equation("D: dimensões 0 e 1")
h2("Alternativa (E)")
p("No primeiro sistema, 12x+16z=24 é quatro vezes 3x+4z=6. Sobram duas equações independentes e dimensão 1. No segundo, y=2 determina y; a equação seguinte determina z; e a primeira determina x. A dimensão é 0.")
equation("E: dimensões 1 e 0")
h2("Alternativa (F)")
p("No primeiro sistema, -16x-28y-12z=-32 é -4 vezes 4x+7y+3z=8. Essa repetição não cria uma nova restrição. A primeira equação e 6y+9z=5 são independentes: duas restrições em três variáveis deixam uma variável livre.")
equation("dimensão do primeiro sistema = 3 - 2 = 1")
p("No segundo sistema, 16x+28y+12z=32 e -20x-36y=-8 não são múltiplas, pois somente a primeira possui termo em z. São duas equações independentes em três variáveis.")
equation("dimensão do segundo sistema = 3 - 2 = 1")
answer("alternativa (F)")

# Q3
new_question(3, "Pertencimento a um plano em R<super>4</super>")
p("O ponto (6,-9,-4,k) pertence ao plano (3,-1,-2,-1) + span{(-2,3,2,1),(-1,-2,2,-1)}. Portanto, existem escalares λ e μ tais que:")
equation("(6,-9,-4,k) = (3,-1,-2,-1) + λ(-2,3,2,1) + μ(-1,-2,2,-1)")
p("Comparando as quatro coordenadas:")
equation("3 - 2λ - μ = 6", "-1 + 3λ - 2μ = -9", "-2 + 2λ + 2μ = -4", "-1 + λ - μ = k")
p("Da primeira e da terceira equações:")
equation("2λ + μ = -3", "λ + μ = -1")
p("Subtraindo a segunda dessas duas igualdades da primeira, obtemos λ = -2. Então -2 + μ = -1, logo μ = 1.")
p("Conferência na segunda coordenada:")
equation("-1 + 3(-2) - 2(1) = -1 - 6 - 2 = -9")
p("Agora usamos a quarta coordenada:")
equation("k = -1 + λ - μ = -1 - 2 - 1 = -4")
answer("k = -4, alternativa (E)")

# Q4
new_question(4, "Representação paramétrica em R<super>4</super>")
p("A condição é x1 - 3x4 = -5. Escolhemos x2 = s, x3 = u e x4 = t como variáveis livres.")
equation("x1 = -5 + 3t", "(x1,x2,x3,x4) = (-5+3t,s,u,t)", "= (-5,0,0,0) + s(0,1,0,0) + u(0,0,1,0) + t(3,0,0,1)")
h2("Verificação da alternativa (B)")
p("O ponto inicial é (4,2,1,3). Ele satisfaz a equação porque 4 - 3(3) = -5.")
p("As direções são (3,0,0,1), (0,0,-1,0) e (0,-5,0,0). Uma direção d precisa satisfazer d1 - 3d4 = 0.")
equation("(3,0,0,1): 3 - 3(1) = 0", "(0,0,-1,0): 0 - 3(0) = 0", "(0,-5,0,0): 0 - 3(0) = 0")
p("As três direções são independentes e controlam as três variáveis livres.")
answer("alternativa (B)")

# Q5
new_question(5, "Valor de k para o sistema ter solução")
p("A matriz aumentada representa quatro equações. Primeiro resolvemos as três primeiras e depois obrigamos a quarta a aceitar a mesma solução.")
equation("x + 2y - z = -1", "-2x - 6y + z = 1", "-2x - 2y + 6z = 2", "-2x - 6y + 7z = k")
p("Somando duas vezes a primeira equação à segunda:")
equation("(-2x - 6y + z) + (2x + 4y - 2z) = 1 - 2", "-2y - z = -1", "2y + z = 1  (1)")
p("Somando duas vezes a primeira equação à terceira:")
equation("(-2x - 2y + 6z) + (2x + 4y - 2z) = 2 - 2", "2y + 4z = 0", "y + 2z = 0  (2)")
p("Da equação (2), y = -2z. Substituindo em (1):")
equation("2(-2z) + z = 1", "-3z = 1", "z = -1/3", "y = 2/3")
p("Usando a primeira equação:")
equation("x + 2(2/3) - (-1/3) = -1", "x + 5/3 = -1", "x = -8/3")
p("Substituímos a solução na quarta equação:")
equation("k = -2(-8/3) - 6(2/3) + 7(-1/3)", "k = 16/3 - 4 - 7/3 = 3 - 4 = -1")
answer("k = -1, alternativa (A)")

# Q6
new_question(6, "Centro e raio do círculo")
p("Os pontos são P1=(2,-2), P2=(5,-1) e P3=(-2,-3). Seguiremos primeiro o método solicitado no enunciado, introduzindo c = r² - x0² - y0².")
h2("Método do sistema linear")
p("A fórmula linearizada é (2xi)x0 + (2yi)y0 + c = xi² + yi². Aplicando-a aos três pontos:")
equation("4x0 - 4y0 + c = 8  (1)", "10x0 - 2y0 + c = 26  (2)", "-4x0 - 6y0 + c = 13  (3)")
p("Subtraindo (1) de (2):")
equation("6x0 + 2y0 = 18", "3x0 + y0 = 9  (4)")
p("Subtraindo (1) de (3):")
equation("-8x0 - 2y0 = 5", "4x0 + y0 = -5/2  (5)")
p("Subtraindo (4) de (5):")
equation("x0 = -5/2 - 9 = -23/2 = -11,5")
p("Substituindo em 3x0+y0=9:")
equation("3(-11,5) + y0 = 9", "y0 = 43,5")
p("Portanto, o centro é (-11,5; 43,5). Usando a primeira equação, encontramos c:")
equation("4(-11,5) - 4(43,5) + c = 8", "-46 - 174 + c = 8", "c = 228")
p("Como c = r² - x0² - y0²:")
equation("r² = c + x0² + y0²", "r² = 228 + 132,25 + 1892,25 = 2252,5", "r = sqrt(2252,5) ≈ 47,4605")
p("A opção numericamente mais próxima é 47,5.")
h2("Método alternativo - mediatrizes")
p("A mediatriz entre (2,-2) e (5,-1) é y = -3x + 9. A mediatriz entre (2,-2) e (-2,-3) é y = -4x - 5/2. Igualando-as, obtemos x=-11,5 e depois y=43,5. Esse atalho é útil quando mediatrizes e equações de reta já são familiares.")
answer("r ≈ 47,5, alternativa (F)")

# Q7
new_question(7, "Interseção de dois planos em R<super>4</super>")
p("Usamos parâmetros t,s no primeiro plano e u,v no segundo. No ponto de interseção, as quatro coordenadas das duas representações são iguais.")
equation("2 + t + 2s = 4 - 2u + 2v", "4 - 2t = -4 - 2u", "6 = -2u - 2v", "-5 + 2t + 2s = 6 + 2u + v")
p("Da segunda equação, u=t-4. Da terceira, u+v=-3; portanto, v=1-t.")
p("Substituímos na primeira equação:")
equation("2 + t + 2s = 4 - 2(t-4) + 2(1-t)", "2 + t + 2s = 14 - 4t", "2s = 12 - 5t  (1)")
p("Na quarta equação, o lado direito torna-se:")
equation("6 + 2(t-4) + (1-t) = t - 1")
p("Pela equação (1), o lado esquerdo é:")
equation("-5 + 2t + 2s = -5 + 2t + 12 - 5t = 7 - 3t")
p("Igualando os dois lados:")
equation("7 - 3t = t - 1", "8 = 4t", "t = 2")
p("Então s=1, u=-2 e v=-1. Usando o primeiro plano:")
equation("(2,4,6,-5) + 2(1,-2,0,2) + (2,0,0,2) = (6,0,6,1)")
p("Assim, a primeira coordenada é x1=6.")
answer("x1 = 6, alternativa (E)")

# Q8
new_question(8, "LI, LD e sistemas lineares")
p("O sistema S1 representa av1+bv2+cv3=0. O sistema S2 representa av1+bv2=v3.")
h2("Afirmação I")
p("Se β={v1,v2,v3} é LI, a combinação av1+bv2+cv3=0 só admite a=b=c=0. Portanto, S1 tem solução única, e não infinitas soluções. A afirmação I é falsa.")
h2("Afirmação II")
p("Se β é LD, S2 pode ter solução única. Exemplo: v1=e1, v2=e2 e v3=e1+e2. O conjunto β é LD, mas av1+bv2=v3 possui a solução única a=1 e b=1. A afirmação II é verdadeira.")
h2("Afirmação III")
p("Se β é LI, v3 não pode ser combinação de v1 e v2. Caso S2 tivesse solução, teríamos av1+bv2-v3=0, uma combinação não trivial. Isso contrariaria a independência de β. Portanto, S2 não tem solução e a afirmação III é verdadeira.")
answer("somente II e III são verdadeiras, alternativa (B)")

# Q9
new_question(9, "Vetores em um cubo")
p("Definimos as três arestas independentes a=AD, b=AB e c=AE, tomando A como origem. Então D=a, B=b, E=c, C=a+b, F=b+c e G=a+b+c.")
h2("Sistema S1")
equation("FC = C - F = (a+b) - (b+c) = a-c", "DE = E - D = c-a = -(a-c)", "CF = F - C = -(a-c)")
p("Chamando u=a-c, o sistema αFC+βDE=CF torna-se:")
equation("αu + β(-u) = -u", "α - β = -1")
p("Há uma equação e duas incógnitas. Se β=t, então α=t-1. Logo, S1 tem infinitas soluções.")
h2("Sistema S2")
equation("GD = D - G = a - (a+b+c) = -b-c", "BE = E - B = c-b", "DG = G - D = b+c")
p("A equação αGD+βBE=DG fica:")
equation("α(-b-c) + β(c-b) = b+c", "(-α-β)b + (-α+β)c = b+c")
p("Como b e c são independentes, comparamos os coeficientes:")
equation("-α - β = 1", "-α + β = 1")
p("Somando, -2α=2, logo α=-1. Substituindo, β=0. S2 tem solução única.")
answer("S1 tem infinitas soluções e S2 tem solução única, alternativa (F)")

# Q10
new_question(10, "Quadrado fantástico")
p("Cada valor central é a média dos quatro vizinhos. Multiplicamos cada média por 4 para evitar frações.")
equation("4x - y - z = -23  (1)", "4y - x - w = -19  (2)", "4z - x - w = -15  (3)", "4w - y - z = 13  (4)")
p("Subtraindo (3) de (2):")
equation("4y - 4z = -4", "y = z - 1  (5)")
p("Substituindo (5) em (1):")
equation("4x - (z-1) - z = -23", "4x - 2z = -24", "x = (z-12)/2  (6)")
p("Substituindo (5) em (4):")
equation("4w - (z-1) - z = 13", "4w - 2z = 12", "w = (z+6)/2  (7)")
p("Agora usamos a equação (3). Pelas equações (6) e (7):")
equation("x+w = (z-12)/2 + (z+6)/2 = z-3", "4z - (z-3) = -15", "3z + 3 = -15", "z = -6")
p("Recuperamos as demais incógnitas:")
equation("y = z-1 = -7", "x = (-6-12)/2 = -9", "w = (-6+6)/2 = 0")
p("Conferência: x=(-2-21-7-6)/4=-9; y=(-1-9-18+0)/4=-7; z=(-9-19+0+4)/4=-6; w=(-7-6+7+6)/4=0.")
answer("(x,y,z,w)=(-9,-7,-6,0); z=-6, alternativa (E)")

# Q11
new_question(11, "Teste de subespaços vetoriais")
h2("Afirmação I")
p("A condição a22=-a33 equivale a a22+a33=0, que é uma condição linear homogênea. A matriz nula a satisfaz. Se A e B satisfazem a condição e C=αA+βB, então c22=αa22+βb22=-(αa33+βb33)=-c33. Portanto, o conjunto é subespaço. I é verdadeira.")
h2("Afirmação II")
p("Um sistema não homogêneo tem a forma Ax=b com b diferente de zero. O vetor zero não é solução porque A0=0, e 0 não é b. Como todo subespaço precisa conter o vetor zero, a afirmação II é falsa.")
h2("Afirmação III")
p("A condição é p(2)=7+p(5). Para o polinômio nulo, teríamos 0=7+0, o que é falso. O conjunto não contém o vetor zero e não é subespaço. III é falsa.")
answer("somente I é verdadeira, alternativa (D)")

# Q12
new_question(12, "Dimensão de S em R<super>14</super>")
p("As condições são x2=x12, x11=x8, x1=x6 e x11+x2=x8+x12.")
p("Usando x11=x8 e x2=x12, a última equação transforma-se em x8+x12=x8+x12. Ela é sempre verdadeira e, portanto, redundante.")
p("Restam três restrições independentes em 14 variáveis:")
equation("x1 = x6", "x2 = x12", "x11 = x8")
p("As variáveis livres podem ser escolhidas como x3,x4,x5,x6,x7,x8,x9,x10,x12,x13,x14. São 11 variáveis livres.")
equation("dim(S) = 14 - 3 = 11")
answer("dimensão 11, alternativa (C)")

# Q13
new_question(13, "Dimensão de um espaço gerado")
p("Chamamos os quatro vetores de v1,v2,v3,v4. Verificamos se os últimos podem ser escritos usando os dois primeiros.")
equation("v1=(1,1,0,2)", "v2=(2,5,-2,3)", "v3=(-2,4,-4,-6)", "v4=(0,-9,6,3)")
p("Para v3:")
equation("-6v1 + 2v2 = (-6,-6,0,-12) + (4,10,-4,6)", "= (-2,4,-4,-6) = v3")
p("Para v4:")
equation("6v1 - 3v2 = (6,6,0,12) + (-6,-15,6,-9)", "= (0,-9,6,3) = v4")
p("Assim, v3 e v4 não acrescentam novas direções. Como v1 e v2 não são múltiplos um do outro, são LI.")
equation("span{v1,v2,v3,v4} = span{v1,v2}", "dimensão = 2")
answer("dimensão 2, alternativa (C)")

# Q14
new_question(14, "Dimensão, geração e independência")
p("O espaço vetorial V tem dimensão 4.")
h2("Afirmação I")
p("Em um espaço de dimensão 4, quatro vetores que geram todo o espaço são automaticamente LI e, portanto, formam uma base. A frase 'nem todo conjunto gerador com quatro vetores é base' é falsa.")
h2("Afirmação II")
p("Um conjunto pode ser LI e ter somente um vetor não nulo. Esse conjunto não gera um espaço de dimensão 4. Ser LI não é suficiente para gerar V; seriam necessários quatro vetores LI. A afirmação II é falsa.")
h2("Afirmação III")
p("O número máximo de vetores LI em V é 4. Portanto, qualquer conjunto com cinco vetores é obrigatoriamente LD. A afirmação III é verdadeira.")
answer("somente III é verdadeira, alternativa (B)")

# Q15
new_question(15, "Coordenadas de um polinômio em uma base")
p("Temos p(x)=-9-17x+36x² e a base β={1+x-2x², 2+4x-8x², -1-3x+8x²}. Se [p]β=(a,b,c), então:")
equation("p = a(1+x-2x²) + b(2+4x-8x²) + c(-1-3x+8x²)")
p("Igualamos separadamente os coeficientes constantes, de x e de x²:")
equation("a + 2b - c = -9  (1)", "a + 4b - 3c = -17  (2)", "-2a - 8b + 8c = 36  (3)")
p("Subtraindo (1) de (2):")
equation("2b - 2c = -8", "b - c = -4", "b = c - 4  (4)")
p("Dividindo (3) por -2:")
equation("a + 4b - 4c = -18  (5)")
p("Subtraindo (2) de (5):")
equation("-c = -1", "c = 1")
p("Da equação (4), b=-3. Pela equação (1), a=-2. Portanto [p]β=(-2,-3,1). Conferindo:")
equation("-2(1+x-2x²) - 3(2+4x-8x²) + (-1-3x+8x²)", "= -9 - 17x + 36x²")
answer("c = 1, alternativa (E)")

# Q16
new_question(16, "Independência linear de pares de vetores")
p("Temos S={v1,v2,v3}, A={v1,v2}, B={v1,v3} e C={v2,v3}.")
h2("Afirmação I")
p("Ela é falsa. Tome v1=e1, v2=e2 e v3=2e2. Os vetores são distintos. A={e1,e2} e B={e1,2e2} são LI, mas C={e2,2e2} é LD porque 2e2 é múltiplo de e2.")
h2("Afirmação II")
p("Ela é verdadeira porque afirma apenas que A pode ser LI. Exemplo: v1=e1, v2=e2 e v3=e1+e2. O par A é LI, mas S é LD, pois v3-v1-v2=0.")
h2("Afirmação III")
p("Se os três vetores são coplanares, pertencem a um espaço de dimensão no máximo 2. Nesse plano cabem no máximo dois vetores LI. Portanto, três vetores coplanares são LD. A afirmação III é verdadeira.")
answer("somente II e III são verdadeiras, alternativa (B)")

# Closing summary
story.append(PageBreak())
h1("Resumo dos padrões mais importantes")
p("<b>Planos paramétricos:</b> verifique primeiro o ponto-base; depois confirme que cada direção produz zero na parte homogênea da equação.")
p("<b>Dimensão de sistemas:</b> conte restrições realmente independentes, não simplesmente o número de linhas. Equações múltiplas são repetições.")
p("<b>LI e LD:</b> uma relação não trivial entre vetores prova dependência. Para refutar uma afirmação geral, um contraexemplo simples costuma ser suficiente.")
p("<b>Subespaços:</b> testar o vetor zero é a verificação inicial mais rápida. Condições com termo constante não nulo normalmente falham nesse teste.")
p("<b>Coordenadas em uma base:</b> monte a combinação linear e compare coeficientes da mesma potência.")
note("O objetivo deste material não é decorar as alternativas, mas reconhecer qual ideia básica cada questão está testando. Refazer as contas sem olhar o gabarito é a melhor forma de consolidar o conteúdo.")

OUTPUT.parent.mkdir(parents=True, exist_ok=True)
doc.build(story)
print(OUTPUT)
