# ChinguPlan

Hackathon Project Idea:

Chingu is a mac app that lives in macbook notch. It opens from the notch as a chat interface that can answer questions. The main user-facing roduct is a floating top-center overlay that visually expands from the mac notch.


Feature 1:
Instantaenous screenshot reply. We ask a question to Chingu
Scenario:
I'm using Adobe Premier Pro, and I have a question. Traditionally, I'd have to take a screenshot and write context in the prompt and ask the question in the web chat interface. 
Our solution: Chingu takes a screenshot of your screen when you asked the question, and removes the user's context-prompting midleman effort. It takes screenshot of your screen, and directly feeds the question with the screenshot, and if it needs google it searches and provides a response. 
Example demo:
User has Adobe Premier Pro open, and asks Chingu "How do I add a fading transition between the scene 1 and scene 2?"
Chingu takes a screenshot the moment the user presses Enter to submit prompt to Chingu (It does this because we will tell the user that the screen you want Chingu to see is when you click enter; we will explciitly tell this to user so they know how to use Chingu). It does not run anything (e.g. LLM analysis/VLM/OCR), but only takes screenshot and saves. 
Chingu reads the user's prompt, and determines whether they need to see the screenshot or not. 
This is where the workflow tree diverges to two different outcomes. If determined yes, to answer the user's question, I need to see the screenshot. It goes through route YES. If it is determined that question does not need screenshot context (e.g. what is the time in Boston right now; What is 49x52+10), it goes through route NO. 

Route "NO"":
Example question: "What is the time in bsoton right now"
Just interprets question as LLM input, searches google and outputes LLM response in notch chat thread. 

Route "YES":
Example question: "How do I add a fading transition between the scene 1 and scene 2?"
Feeds question and screenshot to LLM (do we need to do independent OCR/VLM/LLM analysis of screenshot and interprets what's going on in screenshots, outputs this in text and feeds it to LLM with screenshot, the screenshot summary text, and the question? or is this redundant since we provide screenshot + question to LLM the LLM will automatically do this step to answer question). Provides answer. 
The Route "YES" tree diverges here. Chingu determins whether or not the response needs a 

For the hackathon, in order to hedge against the risk of not having a final 

Checkpoint 1: Not even taking screenshot. Have the UI down where you can press a hot key to activate Chingu. This opens the notch interface with text input area + enter. Text box has something like "write question/prompt here" to guide user, and it disapears when the user types something/i forgot what this text box feature is called. User can send questions and get LLM response as chat thread. Checkpoint 1 has ony 1 chat thread, no "new chat" option or "clear context" option. One thread back and forth only. In checkpoint 1, the LLM has no prompt layer for Chingu, its just LLM chat and response feature in your notch. 

Checkpoint 2: 
 




As students, we use LLMs a lot. We often find ourselves switching between tabs, taking screenshots, explaining the situation via text, and ultimately wasting time feeding context to the LLM. Chingu cuts this “middleman effort” by seeing what you see with your eyes. It watches your every move, automatically updating context without any prompting. And when you have questions, just ask. No need for screenshots, no need for context prompting. Just ask your question and get your answer! Chingu is also deeply personal. As it uses MCP, it knows everything about you, and again, it cuts out the context-prompting middleman effort. Not only is it good for productivity-related work, but you can also use it as a personal agent, e.g., sending a message to your mom or replying to that one email. Chingu is a native macOS tool that lives in your nav bar.

