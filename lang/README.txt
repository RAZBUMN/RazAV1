Languages for RazAV1

en.txt has every text of the window. To add a language:

1. Copy en.txt and name the copy after the language code: ro.txt, es.txt, de.txt, fr.txt, pt-BR.txt ...
2. Change the two lines at the top:  language.name = Romana   and   language.code = ro
   [language.name is what Settings > Language shows].
3. Translate only the text after " = ". Never change the key on the left.
4. Keep {0}, {1} ... where they are [numbers and names go there], keep \n [a new line],
   and keep the names of programs and settings: CRF, ISO, SVT-AV1, KNLMeansCL, Opus, VMAF, HDR10.
5. Save as UTF-8 [Notepad: Save as > Encoding > UTF-8], so letters like a, s, t with marks show correctly.
6. Settings > Language, pick it, restart the window.

A line you leave out, or leave empty, stays English, so a half-finished file works too.
The engine output and the logs stay English on purpose: bug reports must be readable by everyone.

When a new version adds texts, they show up in English until your file has them. Compare your
file with the new en.txt: keys that are new there are the lines to add.

Share a translation by opening a pull request or an issue on GitHub with the file attached.
