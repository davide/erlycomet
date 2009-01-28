Intro
	
	This is a fork of http://code.google.com/p/erlycomet/. So you might want to check that out first! ;)

	I've updated the code to:
		- use Dojo 1.2.3 (hosted by google -> Please change the AJAX API key for your own :P)
		- run on yaws (port 80) - you have to apply yaws_1.79_streamcontent_with_timeout.patch to support long-polling on yaws
		- bend it to my will
	
	I did care much about following the Bayeux protocol to the letter. If it works I'm happy. :)
	Also, I don't know much about code ownership/copyright but I put my name on the modules I tainted (no point in blaming other for bad code ;))

Features:

    * Web server support:
          o MochiWeb HTTP toolkit 
		  o Yaws
    * Javascript libraries:
          o dojo
    * Transport types:
          o long-polling
          o callback-polling 
    * optional Bayeux features:
          o Channel globbing
          o Service channels 
    * Easy pluggable custom applications (decoupled from Comet logic)
    * Designed as distributed system from ground up
    * Connection and channel management with distributed in-memory database 

Removed Features:

    * Javascript libraries:
          o http://jquery.com with jquery Comet plugin (from SVN) - the examples are out... the support is probably still there.
    * optional Bayeux features:
          o JSON comment filtered format (to prevent Ajax Hijacking)
			This seems to be deprecated (http://svn.cometd.org/trunk/bayeux/bayeux.html) and it was
			getting in the way of my yaws hacks so I just ditched it. Which happens to be ok according
			to these guys (http://www.openajax.org/whitepapers/Ajax%20and%20Mashup%20Security.php#Preventing_JSON_Hijacking_Attacks).

Demos:

    * Simple echo
    * Server side counter
    * RPC (with custom serverside application)
    * Simple chat
    * Collaborative drawing (currently not working, want to fix it? :))

ToDos (this branch):

    * handle Multi frame operations (Bayeux spec section 8) to overcome the two connection limit
	* add more transport types: Flash (RTMP), iframe, ActiveX (as in gmail for IE), etc.
    * ditch the message routing semantics defined by the bayeux protocol and use erlycomet as a simple frontend for AMQP
	* Comet responses might get cached on proxies. The workaround seems to be message padding...
	* Compare Comet with BOSH (http://xmpp.org/extensions/xep-0124.html) - it doesn't have the problem mentioned above (checkout ejabberd's BOSH implementation).

Project status:

	* Happy!