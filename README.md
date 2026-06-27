# ChinguPlan

Hackathon Project Idea:

Chingu is a AI companion that lives on your macbook (Mac Native). It pops up as a chat overlay interface that can answer questions. The main user-facing product is a floating top-center overlay that visually pops up at the top of your screen (below notch) at the press of a hot-key. There is only one chat thread with no context refresh option and only one session. If you quit the app, the session is erased and context resets. The UI is a fixed height and width, and you can scroll through the chat interface. 

Problem and Solution:

As students, we use LLMs a lot. We often find ourselves switching between tabs, taking screenshots, explaining the situation via text, and ultimately wasting time feeding context to the LLM. Chingu cuts this “middleman effort” by seeing what you see with your eyes. It watches your every move. And when you have questions, just ask. No need for screenshots, no need for context prompting. Just ask your question and get your answer! Also, Chingu has a pointer interface for instructional questions, to guide you exactly how to do something on your computer (for demo, only button map navigation). 


For the hackathon, in order to hedge against the risk of not having a final working product, we will develop in checkpoints so that when we don't finish a checkpoing we film demo with fallback checkpoint. 


Checkpoint 1 (most important! Setting up ground work and working UI in Mac): Not even taking screenshot. Have the UI down where you can press a hot key to activate Chingu. This opens the notch interface with text input area + enter. Text box has something like "write question/prompt here" to guide user, and it disapears when the user clicks a button. User can send questions and follow ups, and get LLM responses as chat thread. Checkpoint 1 has ony 1 chat thread, no "new chat" option or "clear context" option. One thread back and forth only. In checkpoint 1, the LLM has no prompt layer for Chingu, its just LLM chat and response feature in your notch. It must be able to do websearch.

Checkpoint 2: Rudimentary implementation of the screenshot feature. The user is able to ask contextual questions such as “what does this mean in english?” or “ summarize what is going on in my screen”. The ai answers these questions in the pop up, and the user can ask follow up questions. However, the ai is not able to give specific point outs on the screen yet. So all in all, it is checkpoint 1 + screenshot after user presses “enter” and use a context. Feed picture + user prompt into LLM and get a response. But Chingu has to be able to determine in order to answer the user’s question, whether or not you need to see the screenshot. 

Checkpoint 3: 
Checkpoint 3a: The ai is able to give specific instructions, with a way of showing the user where exactly on the screen to click (pointer, circle, etc.). This is useful for answering questions like, how do I bold this text or how to I insert a transition. It only guides to click the first button, and if there is a overflow menu with multiple sequence of selections, it outputs this tree as text. It only does the first button/instruction. if there are further directions after this, it outputs the steps tree via text for the user to follow. 
Checkpoint 3b: Impementation of 3a but for multi step. So if it is to guide through a overflow button menu with multiple sequences the flow will be like this: 
1. put circle over first button, instruct user to ask whats next when click that button. The user clicks button which opens more buttons, user then types whats next in chat, and runs the loop again. This is a tricky engineering issue bc for you to click to type whats next in chat, it wld close the button menu you clicked, essentially putting you back at square zero. and you can't have the LLM taking frame by frame to see if you clicked properly, it neesd to be indicated when click is done. What is clever solution for this? 

Checkpoint 4: Speech integrations. The ai can automatically detect when the user is done asking its question, and when the user is asking a follow up question via speech. (Optional, voice activation feature “야 친구!” like ‘hey siri’). There will still be a button to end the conversation. The ai also has an text to speech integration to give its response as speech as well. This improves fluid conversation between the user and the ai, as well as remove the need for the user to move the mouse and type to ask questions (usefull when following instructions). 


example scenario to see how app would work: 
I'm using Adobe Premier Pro, and I have a question. Traditionally, I'd have to take a screenshot and write context in the prompt and ask the question in the web chat interface. 
Our solution: Chingu takes a screenshot of your screen when you asked the question, and removes the user's context-prompting midleman effort. It takes screenshot of your screen (the moment you press enter to send question; is there a way to take the screenshot without the chingu app overlay? because if the screenshot includes the overlay then it doesnt take photo of whats behind, and its inefficient for use to manuever around the overlay), and directly feeds the question with the screenshot, and if it needs google it searches and provides a response. 
Example demo:
User has Adobe Premier Pro open, and asks Chingu "How do I add a fading transition between the scene 1 and scene 2?"
Chingu takes a screenshot the moment the user presses Enter to submit prompt to Chingu (It does this because we will tell the user that the screen you want Chingu to see is when you click enter; we will explciitly tell this to user so they know how to use Chingu). It does not run anything (e.g. LLM analysis/VLM/OCR), but only takes screenshot and saves. 
Chingu reads the user's prompt, and determines whether they need to see the screenshot or not. 
This is where the workflow tree diverges to two different outcomes. If determined yes, to answer the user's question, I need to see the screenshot. It goes through route YES. If it is determined that question does not need screenshot context (e.g. what is the time in Boston right now; What is 49x52+10), it goes through route NO. 

Route "NO"":
Example question: "What is the time in boston right now"
Just interprets question as LLM input, does websearch and outputes LLM response in notch chat thread. 

Route "YES":
Example question: "How do I add a fading transition between the scene 1 and scene 2?"
Feeds question and screenshot to LLM (do we need to do independent OCR/VLM/LLM analysis of screenshot and interprets what's going on in screenshots, outputs this in text and feeds it to LLM with screenshot, the screenshot summary text, and the question? or is this redundant since we provide screenshot + question to LLM the LLM will automatically do this step to answer question). Provides answer. 

The Route "YES" tree diverges here. Chingu determines whether or not the response needs a cursor overlay feature (e,g, guiding user to click this button to find the fading transition feature on Premier Pro. It does this by overlaying a circle on top the initial button. This is done via feeding screenshot into LLM, finding exact coordinates of where the button is, and then relayed to Chingu to overlay the circle at said coordinates.) 
