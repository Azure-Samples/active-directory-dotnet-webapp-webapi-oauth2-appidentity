/*
 The MIT License (MIT)

Copyright (c) 2015 Microsoft Corporation

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Configuration;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Claims;
using System.Web;
using System.Web.Http;
using TodoListService.Models;

namespace TodoListService.Controllers
{
    [Authorize]
    public class TodoListController : ApiController
    {
        //
        // To Do items list for all users.  Since the list is stored in memory, it will go away if the service is cycled.
        //
        private static ConcurrentBag<TodoItem> todoBag = new ConcurrentBag<TodoItem>();

        private static string trustedCallerClientId = ConfigurationManager.AppSettings["todo:TrustedCallerClientId"];

        // GET api/todolist
        public IEnumerable<TodoItem> Get()
        {
            //
            // The Scope claim tells you what permissions the client application has in the service.
            // In this case we look for a scope value of user_impersonation, or full access to the service as the user.
            //
            Claim scopeClaim = ClaimsPrincipal.Current.FindFirst("http://schemas.microsoft.com/identity/claims/scope");
            if (scopeClaim != null)
            {
                if (scopeClaim.Value != "user_impersonation")
                {
                    throw new HttpResponseException(new HttpResponseMessage { StatusCode = HttpStatusCode.Unauthorized, ReasonPhrase = "The Scope claim does not contain 'user_impersonation' or scope claim not found" });
                }
            }

            //
            // If the Owner ID parameter has been set, the caller is trying the trusted sub-system pattern.
            // Verify the caller is trusted, then return the To Do list for the specified Owner ID.
            //
            string ownerid = HttpContext.Current.Request.QueryString["ownerid"];
            if (ownerid != null)
            {
                string currentCallerClientId = ClaimsPrincipal.Current.FindFirst("appid").Value;
                if (currentCallerClientId == trustedCallerClientId)
                {
                    return from todo in todoBag
                           where todo.Owner == ownerid
                           select todo;
                }
                else
                {
                    throw new HttpResponseException(
                        new HttpResponseMessage { StatusCode = HttpStatusCode.Unauthorized, ReasonPhrase = "Only trusted callers can return any user's To-Do List.  Caller's OID:" + currentCallerClientId });
                }
            }

            // A user's To Do list is keyed off of the Object Identifier claim, which contains an immutable, unique identifier for the user.
            Claim subject = ClaimsPrincipal.Current.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier");

            return from todo in todoBag
                   where todo.Owner == subject.Value
                   select todo;
        }

        // POST api/todolist
        public void Post(TodoItem todo)
        {
            Claim scopeClaim = ClaimsPrincipal.Current.FindFirst("http://schemas.microsoft.com/identity/claims/scope");
            if (scopeClaim != null)
            {
                if (scopeClaim.Value != "user_impersonation")
                {
                    throw new HttpResponseException(new HttpResponseMessage { StatusCode = HttpStatusCode.Unauthorized, ReasonPhrase = "The Scope claim does not contain 'user_impersonation' or scope claim not found" });
                }
            }

            //
            // If the caller is the trusted caller, then add the To Do item to owner's To Do list as specified in the posted item.
            //
            Claim currentCallerClientIdClaim = ClaimsPrincipal.Current.FindFirst("appid");
            if (currentCallerClientIdClaim != null)
            {
                string currentCallerClientId = currentCallerClientIdClaim.Value;
                if (currentCallerClientId == trustedCallerClientId)
                {
                    todoBag.Add(new TodoItem { Title = todo.Title, Owner = todo.Owner });
                    return;
                }
            }

            if (null != todo && !string.IsNullOrWhiteSpace(todo.Title))
            {
                todoBag.Add(new TodoItem { Title = todo.Title, Owner = ClaimsPrincipal.Current.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier").Value });
            }
        }
    }
}